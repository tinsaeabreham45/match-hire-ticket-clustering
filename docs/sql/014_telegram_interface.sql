-- Telegram intake, human review, and engineering delivery adapter.
-- Apply after 001-013. No bot token or webhook secret is stored in Postgres.

SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS telegram_updates (
  update_id bigint PRIMARY KEY,
  update_kind text NOT NULL CHECK (update_kind IN ('message', 'callback_query', 'unsupported')),
  chat_id bigint,
  actor_user_id bigint,
  status text NOT NULL DEFAULT 'received'
    CHECK (status IN ('received', 'processing', 'completed', 'ignored', 'rate_limited', 'failed')),
  error_code text,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

CREATE INDEX IF NOT EXISTS telegram_updates_actor_rate_idx
  ON telegram_updates (actor_user_id, received_at DESC)
  WHERE actor_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS telegram_connections (
  role text PRIMARY KEY CHECK (role IN ('review', 'engineering')),
  chat_id bigint NOT NULL UNIQUE,
  chat_type text NOT NULL CHECK (chat_type IN ('group', 'supergroup', 'channel')),
  title text,
  active boolean NOT NULL DEFAULT true,
  connected_by_user_id bigint NOT NULL,
  connected_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS authorized_telegram_approvers (
  telegram_user_id bigint PRIMARY KEY,
  display_name text,
  active boolean NOT NULL DEFAULT true,
  added_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS telegram_setup_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  role text NOT NULL CHECK (role IN ('review', 'engineering')),
  code_hash bytea NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  used_by_user_id bigint,
  used_in_chat_id bigint,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS telegram_ticket_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id bigint NOT NULL,
  telegram_user_id bigint NOT NULL,
  state text NOT NULL DEFAULT 'idle'
    CHECK (state IN ('idle', 'drafting', 'preview', 'queued', 'open')),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  draft_text text,
  draft_update_id bigint,
  ticket_id uuid REFERENCES tickets(id) ON DELETE SET NULL,
  opened_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (chat_id, telegram_user_id)
);

CREATE TABLE IF NOT EXISTS telegram_intake_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_event_id text NOT NULL UNIQUE,
  session_id uuid NOT NULL REFERENCES telegram_ticket_sessions(id) ON DELETE CASCADE,
  chat_id bigint NOT NULL,
  telegram_user_id bigint NOT NULL,
  ticket_text text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'retry_wait', 'completed', 'failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz,
  last_error text,
  ticket_id uuid REFERENCES tickets(id) ON DELETE SET NULL,
  cluster_id uuid REFERENCES clusters(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS telegram_intake_jobs_due_idx
  ON telegram_intake_jobs (status, next_attempt_at)
  WHERE status IN ('pending', 'retry_wait');

CREATE TABLE IF NOT EXISTS telegram_case_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
  update_id bigint NOT NULL UNIQUE REFERENCES telegram_updates(update_id) ON DELETE RESTRICT,
  telegram_user_id bigint NOT NULL,
  text text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS telegram_case_messages_ticket_idx
  ON telegram_case_messages (ticket_id, created_at);

CREATE TABLE IF NOT EXISTS telegram_review_surfaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL CHECK (subject_type IN ('report', 'investigation')),
  report_draft_id uuid REFERENCES cluster_report_drafts(id) ON DELETE CASCADE,
  investigation_id uuid REFERENCES cluster_investigations(id) ON DELETE CASCADE,
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  chat_id bigint NOT NULL,
  message_id bigint,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'decided', 'superseded', 'delivery_failed')),
  decision text,
  decided_by_user_id bigint,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (subject_type = 'report' AND report_draft_id IS NOT NULL AND investigation_id IS NULL)
    OR
    (subject_type = 'investigation' AND investigation_id IS NOT NULL AND report_draft_id IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS telegram_review_surfaces_report_uidx
  ON telegram_review_surfaces (report_draft_id) WHERE subject_type = 'report';
CREATE UNIQUE INDEX IF NOT EXISTS telegram_review_surfaces_investigation_uidx
  ON telegram_review_surfaces (investigation_id) WHERE subject_type = 'investigation';

CREATE TABLE IF NOT EXISTS telegram_callback_tokens (
  token text PRIMARY KEY,
  purpose text NOT NULL CHECK (purpose IN ('ticket', 'review', 'investigation')),
  action text NOT NULL CHECK (action IN ('confirm', 'cancel', 'approve', 'reject', 'split', 'retry', 'dismiss')),
  chat_id bigint NOT NULL,
  telegram_user_id bigint,
  session_id uuid REFERENCES telegram_ticket_sessions(id) ON DELETE CASCADE,
  session_version integer,
  surface_id uuid REFERENCES telegram_review_surfaces(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  callback_query_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS telegram_callback_tokens_expiry_idx
  ON telegram_callback_tokens (expires_at) WHERE used_at IS NULL;

CREATE TABLE IF NOT EXISTS telegram_decision_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  callback_query_id text NOT NULL UNIQUE,
  surface_id uuid REFERENCES telegram_review_surfaces(id) ON DELETE SET NULL,
  cluster_id uuid REFERENCES clusters(id) ON DELETE SET NULL,
  action text,
  actor_user_id bigint,
  chat_id bigint,
  outcome text NOT NULL,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE cluster_report_drafts
  ADD COLUMN IF NOT EXISTS delivery_channel text NOT NULL DEFAULT 'slack';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'cluster_report_drafts_delivery_channel_check'
  ) THEN
    ALTER TABLE cluster_report_drafts
      ADD CONSTRAINT cluster_report_drafts_delivery_channel_check
      CHECK (delivery_channel IN ('slack', 'telegram'));
  END IF;
END;
$$;

ALTER TABLE delivery_attempts
  ADD COLUMN IF NOT EXISTS destination_ref text;

ALTER TABLE delivery_attempts DROP CONSTRAINT IF EXISTS delivery_attempts_target_check;
ALTER TABLE delivery_attempts
  ADD CONSTRAINT delivery_attempts_target_check
  CHECK (target IN ('google_doc', 'google_sheets', 'eng_slack', 'eng_telegram'));

CREATE OR REPLACE FUNCTION create_telegram_setup_code(
  p_role text,
  p_ttl interval DEFAULT interval '15 minutes'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ticket_cluster, public
AS $$
DECLARE v_code text;
BEGIN
  IF p_role NOT IN ('review', 'engineering') THEN
    RAISE EXCEPTION 'unsupported Telegram connection role';
  END IF;
  IF p_ttl <= interval '0 seconds' OR p_ttl > interval '1 hour' THEN
    RAISE EXCEPTION 'setup-code lifetime must be between 1 second and 1 hour';
  END IF;

  v_code := upper(encode(gen_random_bytes(6), 'hex'));
  INSERT INTO telegram_setup_codes (role, code_hash, expires_at)
  VALUES (p_role, digest(v_code, 'sha256'), now() + p_ttl);
  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION register_telegram_update(
  p_update_id bigint,
  p_update_kind text,
  p_chat_id bigint,
  p_actor_user_id bigint,
  p_rate_limit integer DEFAULT 30
)
RETURNS TABLE (accepted boolean, disposition text)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_recent integer;
BEGIN
  INSERT INTO telegram_updates (update_id, update_kind, chat_id, actor_user_id)
  VALUES (
    p_update_id,
    CASE WHEN p_update_kind IN ('message', 'callback_query') THEN p_update_kind ELSE 'unsupported' END,
    p_chat_id,
    p_actor_user_id
  ) ON CONFLICT (update_id) DO NOTHING;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'duplicate'::text;
    RETURN;
  END IF;

  IF p_actor_user_id IS NOT NULL THEN
    SELECT count(*)::integer INTO v_recent
    FROM telegram_updates
    WHERE actor_user_id = p_actor_user_id
      AND received_at > now() - interval '1 minute';
    IF v_recent > p_rate_limit THEN
      UPDATE telegram_updates SET status = 'rate_limited', processed_at = now()
      WHERE update_id = p_update_id;
      RETURN QUERY SELECT false, 'rate_limited'::text;
      RETURN;
    END IF;
  END IF;

  UPDATE telegram_updates SET status = 'processing' WHERE update_id = p_update_id;
  RETURN QUERY SELECT true, 'accepted'::text;
END;
$$;

CREATE OR REPLACE FUNCTION complete_telegram_update(
  p_update_id bigint,
  p_status text DEFAULT 'completed'
)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  IF p_status NOT IN ('completed', 'ignored', 'failed') THEN
    RAISE EXCEPTION 'invalid Telegram update completion status';
  END IF;
  UPDATE telegram_updates
  SET status = p_status, processed_at = now()
  WHERE update_id = p_update_id AND status IN ('received', 'processing');
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION consume_telegram_setup_code(
  p_code text,
  p_role text,
  p_chat_id bigint,
  p_chat_type text,
  p_chat_title text,
  p_actor_user_id bigint,
  p_actor_name text
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_code telegram_setup_codes%ROWTYPE;
BEGIN
  IF p_role NOT IN ('review', 'engineering') THEN RETURN 'invalid_role'; END IF;
  IF p_chat_type NOT IN ('group', 'supergroup', 'channel') THEN RETURN 'group_required'; END IF;

  SELECT * INTO v_code
  FROM telegram_setup_codes
  WHERE role = p_role
    AND code_hash = digest(upper(btrim(p_code)), 'sha256')
  FOR UPDATE;

  IF NOT FOUND OR v_code.used_at IS NOT NULL OR v_code.expires_at <= now() THEN
    RETURN 'invalid_or_expired_code';
  END IF;

  INSERT INTO telegram_connections (role, chat_id, chat_type, title, connected_by_user_id)
  VALUES (p_role, p_chat_id, p_chat_type, nullif(p_chat_title, ''), p_actor_user_id)
  ON CONFLICT (role) DO UPDATE
    SET chat_id = EXCLUDED.chat_id,
        chat_type = EXCLUDED.chat_type,
        title = EXCLUDED.title,
        active = true,
        connected_by_user_id = EXCLUDED.connected_by_user_id,
        updated_at = now();

  IF p_role = 'review' THEN
    INSERT INTO authorized_telegram_approvers (telegram_user_id, display_name)
    VALUES (p_actor_user_id, nullif(p_actor_name, ''))
    ON CONFLICT (telegram_user_id) DO UPDATE
      SET display_name = coalesce(EXCLUDED.display_name, authorized_telegram_approvers.display_name),
          active = true,
          revoked_at = NULL;
  END IF;

  UPDATE telegram_setup_codes
  SET used_at = now(), used_by_user_id = p_actor_user_id, used_in_chat_id = p_chat_id
  WHERE id = v_code.id;
  RETURN 'connected';
END;
$$;

CREATE OR REPLACE FUNCTION handle_telegram_message(
  p_update_id bigint,
  p_chat_id bigint,
  p_chat_type text,
  p_actor_user_id bigint,
  p_actor_name text,
  p_text text
)
RETURNS TABLE (
  operation text,
  reply_text text,
  confirm_token text,
  cancel_token text,
  ticket_id uuid
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_session telegram_ticket_sessions%ROWTYPE;
  v_text text := btrim(coalesce(p_text, ''));
  v_command text;
  v_parts text[];
  v_result text;
  v_confirm text;
  v_cancel text;
BEGIN
  IF v_text ~ '^/connect(@[A-Za-z0-9_]+)?[[:space:]]+' THEN
    v_parts := regexp_split_to_array(v_text, '[[:space:]]+');
    IF array_length(v_parts, 1) <> 3 THEN
      RETURN QUERY SELECT 'reply', 'Use /connect review CODE or /connect engineering CODE.', NULL::text, NULL::text, NULL::uuid;
      RETURN;
    END IF;
    v_result := consume_telegram_setup_code(
      v_parts[3], lower(v_parts[2]), p_chat_id, p_chat_type,
      '', p_actor_user_id, p_actor_name
    );
    RETURN QUERY SELECT 'reply', CASE v_result
      WHEN 'connected' THEN 'Connection saved. This setup code is now disabled.'
      WHEN 'group_required' THEN 'Run this command inside the private Telegram group being connected.'
      ELSE 'The setup code is invalid, expired, or does not match this role.'
    END, NULL::text, NULL::text, NULL::uuid;
    RETURN;
  END IF;

  IF p_chat_type <> 'private' THEN
    RETURN QUERY SELECT 'ignore', 'Ticket intake is available only in a private chat with this bot.', NULL::text, NULL::text, NULL::uuid;
    RETURN;
  END IF;

  INSERT INTO telegram_ticket_sessions (chat_id, telegram_user_id)
  VALUES (p_chat_id, p_actor_user_id)
  ON CONFLICT (chat_id, telegram_user_id) DO NOTHING;
  SELECT * INTO v_session FROM telegram_ticket_sessions
  WHERE chat_id = p_chat_id AND telegram_user_id = p_actor_user_id
  FOR UPDATE;

  v_command := lower(regexp_replace(split_part(v_text, ' ', 1), '@[A-Za-z0-9_]+$', ''));
  IF v_command IN ('/start', '/help') THEN
    RETURN QUERY SELECT 'reply', E'TriagePulse support bot\n\n/new — create a ticket\n/status — show the current ticket\n/close — close the current ticket\n/help — show this guide', NULL::text, NULL::text, v_session.ticket_id;
    RETURN;
  ELSIF v_command = '/new' THEN
    IF v_session.state IN ('queued', 'open') THEN
      RETURN QUERY SELECT 'reply', CASE WHEN v_session.state='queued'
        THEN 'Your previous ticket is still being processed. Use /status to check it.'
        ELSE 'You already have an open ticket. Send a follow-up, or use /close before creating another.' END,
        NULL::text, NULL::text, v_session.ticket_id;
      RETURN;
    END IF;
    UPDATE telegram_ticket_sessions
    SET state = 'drafting', version = version + 1, draft_text = NULL,
        draft_update_id = NULL, ticket_id = NULL, closed_at = NULL, updated_at = now()
    WHERE id = v_session.id;
    RETURN QUERY SELECT 'reply', 'Describe the problem in one message. Include what failed, who is affected, and any error you saw.', NULL::text, NULL::text, NULL::uuid;
    RETURN;
  ELSIF v_command = '/status' THEN
    RETURN QUERY SELECT 'reply', CASE v_session.state
      WHEN 'open' THEN 'Your ticket is open. Reference: ' || v_session.ticket_id::text || '. Send another message to add evidence, or /close when resolved.'
      WHEN 'queued' THEN 'Your ticket is safely queued for processing. The bot will post its reference here when ready.'
      WHEN 'drafting' THEN 'A ticket draft is waiting for your description.'
      WHEN 'preview' THEN 'A ticket preview is waiting for confirmation.'
      ELSE 'You have no open ticket. Use /new to create one.'
    END, NULL::text, NULL::text, v_session.ticket_id;
    RETURN;
  ELSIF v_command = '/close' THEN
    IF v_session.state <> 'open' THEN
      RETURN QUERY SELECT 'reply', 'There is no open ticket to close.', NULL::text, NULL::text, v_session.ticket_id;
      RETURN;
    END IF;
    UPDATE telegram_ticket_sessions
    SET state = 'idle', version = version + 1, closed_at = now(), updated_at = now()
    WHERE id = v_session.id;
    RETURN QUERY SELECT 'reply', 'Ticket closed. Use /new whenever you need more help.', NULL::text, NULL::text, v_session.ticket_id;
    RETURN;
  ELSIF left(v_command, 1) = '/' THEN
    RETURN QUERY SELECT 'reply', 'Unknown command. Use /help to see available commands.', NULL::text, NULL::text, v_session.ticket_id;
    RETURN;
  END IF;

  IF v_session.state = 'drafting' THEN
    IF char_length(v_text) < 10 THEN
      RETURN QUERY SELECT 'reply', 'Please provide at least 10 characters so the issue can be investigated.', NULL::text, NULL::text, NULL::uuid;
      RETURN;
    END IF;
    IF char_length(v_text) > 10000 THEN
      RETURN QUERY SELECT 'reply', 'That description is too long. Please shorten it to 10,000 characters.', NULL::text, NULL::text, NULL::uuid;
      RETURN;
    END IF;

    UPDATE telegram_ticket_sessions
    SET state = 'preview', version = version + 1, draft_text = v_text,
        draft_update_id = p_update_id, updated_at = now()
    WHERE id = v_session.id
    RETURNING * INTO v_session;

    v_confirm := encode(gen_random_bytes(16), 'hex');
    v_cancel := encode(gen_random_bytes(16), 'hex');
    INSERT INTO telegram_callback_tokens (
      token, purpose, action, chat_id, telegram_user_id,
      session_id, session_version, expires_at
    ) VALUES
      (v_confirm, 'ticket', 'confirm', p_chat_id, p_actor_user_id, v_session.id, v_session.version, now() + interval '30 minutes'),
      (v_cancel, 'ticket', 'cancel', p_chat_id, p_actor_user_id, v_session.id, v_session.version, now() + interval '30 minutes');
    RETURN QUERY SELECT 'preview', E'Please confirm this ticket:\n\n' || v_text, v_confirm, v_cancel, NULL::uuid;
    RETURN;
  ELSIF v_session.state = 'preview' THEN
    RETURN QUERY SELECT 'reply', 'Use the Confirm or Cancel button on the current preview.', NULL::text, NULL::text, NULL::uuid;
    RETURN;
  ELSIF v_session.state = 'open' THEN
    INSERT INTO telegram_case_messages (ticket_id, update_id, telegram_user_id, text)
    VALUES (v_session.ticket_id, p_update_id, p_actor_user_id, v_text)
    ON CONFLICT (update_id) DO NOTHING;
    RETURN QUERY SELECT 'reply', 'Follow-up added to ticket ' || v_session.ticket_id::text || '. It adds evidence without creating a second affected customer.', NULL::text, NULL::text, v_session.ticket_id;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'reply', 'Use /new to create a support ticket.', NULL::text, NULL::text, NULL::uuid;
END;
$$;

CREATE OR REPLACE FUNCTION create_telegram_review_surface(
  p_subject_type text,
  p_subject_id uuid
)
RETURNS TABLE (
  surface_id uuid,
  chat_id bigint,
  cluster_id uuid,
  approve_token text,
  reject_token text,
  split_token text,
  retry_token text,
  dismiss_token text
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_chat_id bigint;
  v_surface telegram_review_surfaces%ROWTYPE;
  v_cluster_id uuid;
  v_approve text;
  v_reject text;
  v_split text;
  v_retry text;
  v_dismiss text;
BEGIN
  SELECT c.chat_id INTO v_chat_id FROM telegram_connections c
  WHERE c.role = 'review' AND c.active;
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'Telegram review group is not connected'; END IF;

  IF p_subject_type = 'report' THEN
    SELECT d.cluster_id INTO v_cluster_id FROM cluster_report_drafts d WHERE d.id = p_subject_id;
    IF v_cluster_id IS NULL THEN RAISE EXCEPTION 'unknown report draft'; END IF;
    INSERT INTO telegram_review_surfaces (subject_type, report_draft_id, cluster_id, chat_id)
    VALUES ('report', p_subject_id, v_cluster_id, v_chat_id)
    ON CONFLICT (report_draft_id) WHERE subject_type = 'report' DO NOTHING;
    SELECT s.* INTO v_surface FROM telegram_review_surfaces s WHERE s.report_draft_id = p_subject_id;
  ELSIF p_subject_type = 'investigation' THEN
    SELECT i.cluster_id INTO v_cluster_id FROM cluster_investigations i WHERE i.id = p_subject_id;
    IF v_cluster_id IS NULL THEN RAISE EXCEPTION 'unknown investigation'; END IF;
    INSERT INTO telegram_review_surfaces (subject_type, investigation_id, cluster_id, chat_id)
    VALUES ('investigation', p_subject_id, v_cluster_id, v_chat_id)
    ON CONFLICT (investigation_id) WHERE subject_type = 'investigation' DO NOTHING;
    SELECT s.* INTO v_surface FROM telegram_review_surfaces s WHERE s.investigation_id = p_subject_id;
  ELSE
    RAISE EXCEPTION 'unsupported Telegram review subject';
  END IF;

  IF v_surface.status <> 'pending' THEN RAISE EXCEPTION 'Telegram review is already decided'; END IF;

  IF NOT EXISTS (SELECT 1 FROM telegram_callback_tokens t WHERE t.surface_id = v_surface.id AND t.used_at IS NULL) THEN
    v_split := encode(gen_random_bytes(16), 'hex');
    IF p_subject_type = 'report' THEN
      v_approve := encode(gen_random_bytes(16), 'hex');
      v_reject := encode(gen_random_bytes(16), 'hex');
      INSERT INTO telegram_callback_tokens (token,purpose,action,chat_id,surface_id,expires_at)
      VALUES
        (v_approve,'review','approve',v_chat_id,v_surface.id,now()+interval '7 days'),
        (v_reject,'review','reject',v_chat_id,v_surface.id,now()+interval '7 days'),
        (v_split,'review','split',v_chat_id,v_surface.id,now()+interval '7 days');
    ELSE
      v_retry := encode(gen_random_bytes(16), 'hex');
      v_dismiss := encode(gen_random_bytes(16), 'hex');
      INSERT INTO telegram_callback_tokens (token,purpose,action,chat_id,surface_id,expires_at)
      VALUES
        (v_retry,'investigation','retry',v_chat_id,v_surface.id,now()+interval '7 days'),
        (v_dismiss,'investigation','dismiss',v_chat_id,v_surface.id,now()+interval '7 days'),
        (v_split,'investigation','split',v_chat_id,v_surface.id,now()+interval '7 days');
    END IF;
  END IF;

  SELECT max(token) FILTER (WHERE action='approve'), max(token) FILTER (WHERE action='reject'),
         max(token) FILTER (WHERE action='split'), max(token) FILTER (WHERE action='retry'),
         max(token) FILTER (WHERE action='dismiss')
  INTO v_approve,v_reject,v_split,v_retry,v_dismiss
  FROM telegram_callback_tokens t WHERE t.surface_id=v_surface.id AND t.used_at IS NULL;

  RETURN QUERY SELECT v_surface.id,v_surface.chat_id,v_surface.cluster_id,
    v_approve,v_reject,v_split,v_retry,v_dismiss;
END;
$$;

CREATE OR REPLACE FUNCTION mark_telegram_review_surface_sent(
  p_surface_id uuid,
  p_message_id bigint
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_surface telegram_review_surfaces%ROWTYPE;
BEGIN
  UPDATE telegram_review_surfaces
  SET message_id = p_message_id, updated_at = now()
  WHERE id = p_surface_id AND status = 'pending'
  RETURNING * INTO v_surface;
  IF NOT FOUND THEN RAISE EXCEPTION 'pending Telegram review surface not found'; END IF;

  IF v_surface.subject_type = 'investigation' THEN
    UPDATE cluster_investigations SET notified_at = now(), updated_at = now()
    WHERE id = v_surface.investigation_id AND status = 'open';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION process_telegram_callback(
  p_update_id bigint,
  p_callback_query_id text,
  p_token text,
  p_actor_user_id bigint,
  p_chat_id bigint,
  p_message_id bigint
)
RETURNS TABLE (
  operation text,
  outcome text,
  answer_text text,
  ticket_text text,
  source_event_id text,
  cluster_id uuid,
  report_draft_id uuid,
  investigation_id uuid
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_token telegram_callback_tokens%ROWTYPE;
  v_session telegram_ticket_sessions%ROWTYPE;
  v_surface telegram_review_surfaces%ROWTYPE;
  v_cluster clusters%ROWTYPE;
  v_draft cluster_report_drafts%ROWTYPE;
  v_investigation cluster_investigations%ROWTYPE;
  v_outcome text;
BEGIN
  SELECT * INTO v_token FROM telegram_callback_tokens
  WHERE token = p_token FOR UPDATE;

  IF NOT FOUND OR v_token.used_at IS NOT NULL OR v_token.expires_at <= now() THEN
    RETURN QUERY SELECT 'noop','invalid_or_expired','This action has expired or was already processed.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;
  IF v_token.chat_id <> p_chat_id THEN
    RETURN QUERY SELECT 'noop','denied_unexpected_context','This action is not valid in this chat.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;

  IF v_token.purpose = 'ticket' THEN
    IF v_token.telegram_user_id <> p_actor_user_id THEN
      RETURN QUERY SELECT 'noop','denied_not_owner','Only the ticket author can use this button.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
      RETURN;
    END IF;
    SELECT * INTO v_session FROM telegram_ticket_sessions
    WHERE id = v_token.session_id FOR UPDATE;
    IF NOT FOUND OR v_session.state <> 'preview' OR v_session.version <> v_token.session_version THEN
      RETURN QUERY SELECT 'noop','stale_preview','This preview is no longer current.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
      RETURN;
    END IF;

    UPDATE telegram_callback_tokens
    SET used_at=now(), callback_query_id=p_callback_query_id
    WHERE session_id=v_session.id AND session_version=v_session.version AND used_at IS NULL;
    IF v_token.action = 'cancel' THEN
      UPDATE telegram_ticket_sessions SET state='idle',version=version+1,draft_text=NULL,draft_update_id=NULL,updated_at=now()
      WHERE id=v_session.id;
      UPDATE telegram_updates SET status='completed',processed_at=now() WHERE update_id=p_update_id;
      RETURN QUERY SELECT 'ticket_cancelled','cancelled','Ticket draft cancelled.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
      RETURN;
    END IF;

    INSERT INTO telegram_intake_jobs (
      source_event_id,session_id,chat_id,telegram_user_id,ticket_text
    ) VALUES (
      'telegram:'||v_session.chat_id::text||':'||v_session.draft_update_id::text,
      v_session.id,v_session.chat_id,v_session.telegram_user_id,v_session.draft_text
    ) ON CONFLICT ON CONSTRAINT telegram_intake_jobs_source_event_id_key DO NOTHING;
    UPDATE telegram_ticket_sessions SET state='queued',updated_at=now() WHERE id=v_session.id;
    RETURN QUERY SELECT 'ticket_queued','queued','Ticket safely queued for processing.',v_session.draft_text,
      'telegram:'||v_session.chat_id::text||':'||v_session.draft_update_id::text,
      NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;

  INSERT INTO telegram_decision_attempts (
    callback_query_id,surface_id,action,actor_user_id,chat_id,outcome
  ) VALUES (p_callback_query_id,v_token.surface_id,v_token.action,p_actor_user_id,p_chat_id,'received')
  ON CONFLICT (callback_query_id) DO NOTHING;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'noop','duplicate_callback','This decision was already received.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM authorized_telegram_approvers
    WHERE telegram_user_id=p_actor_user_id AND active
  ) THEN
    UPDATE telegram_decision_attempts SET outcome='denied_not_authorized' WHERE callback_query_id=p_callback_query_id;
    RETURN QUERY SELECT 'noop','denied_not_authorized','You are not authorized to decide this review.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM telegram_connections
    WHERE role='review' AND chat_id=p_chat_id AND active
  ) THEN
    UPDATE telegram_decision_attempts SET outcome='denied_unexpected_context' WHERE callback_query_id=p_callback_query_id;
    RETURN QUERY SELECT 'noop','denied_unexpected_context','This is not the configured review group.',NULL::text,NULL::text,NULL::uuid,NULL::uuid,NULL::uuid;
    RETURN;
  END IF;

  SELECT * INTO v_surface FROM telegram_review_surfaces WHERE id=v_token.surface_id FOR UPDATE;
  IF NOT FOUND OR v_surface.status <> 'pending' OR v_surface.message_id IS DISTINCT FROM p_message_id THEN
    UPDATE telegram_decision_attempts SET outcome='ignored_not_pending' WHERE callback_query_id=p_callback_query_id;
    RETURN QUERY SELECT 'finalize_card','ignored_not_pending','This review was already processed.',NULL::text,NULL::text,v_surface.cluster_id,v_surface.report_draft_id,v_surface.investigation_id;
    RETURN;
  END IF;

  SELECT * INTO v_cluster FROM clusters WHERE id=v_surface.cluster_id FOR UPDATE;
  IF v_surface.subject_type='report' THEN
    SELECT * INTO v_draft FROM cluster_report_drafts WHERE id=v_surface.report_draft_id FOR UPDATE;
    IF v_cluster.status <> 'pending_review' OR v_draft.status <> 'pending_review' THEN
      v_outcome := 'ignored_not_pending';
    ELSIF v_token.action='approve' THEN
      UPDATE clusters SET status='approved',updated_at=now() WHERE id=v_cluster.id;
      UPDATE cluster_report_drafts SET status='delivery_pending',updated_at=now() WHERE id=v_draft.id;
      PERFORM enqueue_report_delivery(v_draft.id);
      v_outcome := 'delivery_queued';
    ELSIF v_token.action IN ('reject','split') THEN
      UPDATE clusters SET status=CASE v_token.action WHEN 'reject' THEN 'rejected' ELSE 'split' END,updated_at=now() WHERE id=v_cluster.id;
      UPDATE cluster_report_drafts SET status=CASE v_token.action WHEN 'reject' THEN 'rejected' ELSE 'split' END,updated_at=now() WHERE id=v_draft.id;
      v_outcome := CASE v_token.action WHEN 'reject' THEN 'rejected' ELSE 'split' END;
    ELSE
      v_outcome := 'denied_invalid_action';
    END IF;

    IF v_outcome IN ('delivery_queued','rejected','split') THEN
      INSERT INTO cluster_review_actions (cluster_id,report_draft_id,action,actor_id,callback_id,workspace_id,channel_id)
      VALUES (v_cluster.id,v_draft.id,v_token.action,'telegram:'||p_actor_user_id::text,'telegram:'||p_callback_query_id,'telegram',p_chat_id::text);
    END IF;
  ELSE
    SELECT * INTO v_investigation FROM cluster_investigations WHERE id=v_surface.investigation_id FOR UPDATE;
    IF v_cluster.status <> 'needs_review' OR v_investigation.status <> 'open' THEN
      v_outcome := 'ignored_not_open';
    ELSIF v_token.action='retry' THEN
      UPDATE cluster_investigations SET status='retry_requested',updated_at=now() WHERE id=v_investigation.id;
      UPDATE clusters SET status='verification_pending',updated_at=now() WHERE id=v_cluster.id;
      v_outcome := 'retry_queued';
    ELSIF v_token.action IN ('dismiss','split') THEN
      UPDATE cluster_investigations SET status=CASE v_token.action WHEN 'dismiss' THEN 'dismissed' ELSE 'split' END,updated_at=now() WHERE id=v_investigation.id;
      UPDATE clusters SET status=CASE v_token.action WHEN 'dismiss' THEN 'rejected' ELSE 'split' END,updated_at=now() WHERE id=v_cluster.id;
      v_outcome := CASE v_token.action WHEN 'dismiss' THEN 'dismissed' ELSE 'split' END;
    ELSE
      v_outcome := 'denied_invalid_action';
    END IF;

    IF v_outcome IN ('retry_queued','dismissed','split') THEN
      INSERT INTO cluster_investigation_actions (investigation_id,cluster_id,action,actor_id,callback_id,workspace_id,channel_id)
      VALUES (v_investigation.id,v_cluster.id,v_token.action,'telegram:'||p_actor_user_id::text,'telegram:'||p_callback_query_id,'telegram',p_chat_id::text);
    END IF;
  END IF;

  UPDATE telegram_decision_attempts
  SET cluster_id=v_surface.cluster_id,outcome=v_outcome
  WHERE callback_query_id=p_callback_query_id;
  UPDATE telegram_review_surfaces
  SET status=CASE WHEN v_outcome IN ('delivery_queued','rejected','split','retry_queued','dismissed') THEN 'decided' ELSE status END,
      decision=v_outcome,decided_by_user_id=p_actor_user_id,
      decided_at=CASE WHEN v_outcome IN ('delivery_queued','rejected','split','retry_queued','dismissed') THEN now() ELSE decided_at END,
      updated_at=now()
  WHERE id=v_surface.id;
  UPDATE telegram_callback_tokens SET used_at=now(),callback_query_id=p_callback_query_id
  WHERE surface_id=v_surface.id AND used_at IS NULL;
  UPDATE telegram_updates SET status='completed',processed_at=now() WHERE update_id=p_update_id;

  RETURN QUERY SELECT
    CASE WHEN v_outcome='delivery_queued' THEN 'run_delivery' WHEN v_outcome='retry_queued' THEN 'retry_verification' ELSE 'finalize_card' END,
    v_outcome,
    CASE v_outcome
      WHEN 'delivery_queued' THEN 'Approved. Engineering delivery was queued.'
      WHEN 'rejected' THEN 'Review rejected.'
      WHEN 'split' THEN 'Cluster marked for splitting.'
      WHEN 'retry_queued' THEN 'Verification retry queued.'
      WHEN 'dismissed' THEN 'Investigation dismissed.'
      ELSE 'This review is no longer pending.' END,
    NULL::text,NULL::text,v_surface.cluster_id,v_surface.report_draft_id,v_surface.investigation_id;
END;
$$;

CREATE OR REPLACE FUNCTION claim_telegram_intake_job(p_max_attempts integer DEFAULT 5)
RETURNS TABLE (
  job_id uuid,
  source_event_id text,
  ticket_text text,
  chat_id bigint,
  telegram_user_id bigint,
  attempt_number integer
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_job telegram_intake_jobs%ROWTYPE;
BEGIN
  UPDATE telegram_intake_jobs
  SET status=CASE WHEN attempts>=p_max_attempts THEN 'failed' ELSE 'retry_wait' END,
      locked_at=NULL,next_attempt_at=now(),
      last_error=coalesce(last_error,'worker lease expired'),updated_at=now()
  WHERE status='processing' AND locked_at<now()-interval '10 minutes';

  UPDATE telegram_ticket_sessions s
  SET state='drafting',version=version+1,updated_at=now()
  FROM telegram_intake_jobs j
  WHERE j.session_id=s.id AND j.status='failed' AND s.state='queued';

  SELECT * INTO v_job FROM telegram_intake_jobs
  WHERE status IN ('pending','retry_wait') AND next_attempt_at<=now() AND attempts<p_max_attempts
  ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE telegram_intake_jobs
  SET status='processing',attempts=attempts+1,locked_at=now(),updated_at=now()
  WHERE id=v_job.id;
  RETURN QUERY SELECT v_job.id,v_job.source_event_id,v_job.ticket_text,v_job.chat_id,
    v_job.telegram_user_id,v_job.attempts+1;
END;
$$;

CREATE OR REPLACE FUNCTION complete_telegram_intake_job(
  p_job_id uuid,
  p_embedding vector(768),
  p_embedding_model text DEFAULT 'gemini-embedding-001',
  p_workflow_version text DEFAULT 'telegram-v1'
)
RETURNS TABLE (
  ticket_id uuid,
  cluster_id uuid,
  disposition text,
  similarity real,
  review_required boolean,
  chat_id bigint
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_job telegram_intake_jobs%ROWTYPE;
DECLARE v_result record;
BEGIN
  SELECT * INTO v_job FROM telegram_intake_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'processing' THEN RAISE EXCEPTION 'Telegram intake job is not processing'; END IF;

  SELECT * INTO v_result FROM ingest_telegram_ticket(
    v_job.source_event_id,v_job.ticket_text,v_job.created_at,p_embedding,p_embedding_model,
    p_workflow_version,v_job.chat_id,v_job.telegram_user_id
  );
  UPDATE telegram_intake_jobs
  SET status='completed',ticket_id=v_result.ticket_id,cluster_id=v_result.cluster_id,
      locked_at=NULL,last_error=NULL,completed_at=now(),updated_at=now()
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_result.ticket_id,v_result.cluster_id,v_result.disposition,
    v_result.similarity,v_result.review_required,v_job.chat_id;
END;
$$;

CREATE OR REPLACE FUNCTION fail_telegram_intake_job(
  p_job_id uuid,
  p_error text,
  p_max_attempts integer DEFAULT 5
)
RETURNS TABLE (terminal boolean, chat_id bigint, attempts integer)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_job telegram_intake_jobs%ROWTYPE;
BEGIN
  UPDATE telegram_intake_jobs
  SET status=CASE WHEN telegram_intake_jobs.attempts>=p_max_attempts THEN 'failed' ELSE 'retry_wait' END,
      next_attempt_at=CASE WHEN telegram_intake_jobs.attempts>=p_max_attempts THEN next_attempt_at
        ELSE now()+make_interval(secs=>least(900,30*(2^greatest(telegram_intake_jobs.attempts-1,0)))) END,
      locked_at=NULL,last_error=left(coalesce(p_error,'embedding failed'),1000),updated_at=now()
  WHERE id=p_job_id AND status='processing'
  RETURNING * INTO v_job;
  IF NOT FOUND THEN RAISE EXCEPTION 'Telegram intake job is not processing'; END IF;

  IF v_job.status='failed' THEN
    UPDATE telegram_ticket_sessions
    SET state='drafting',version=version+1,updated_at=now()
    WHERE id=v_job.session_id AND state='queued';
    PERFORM record_workflow_failure(
      'telegram-interface',v_job.id::text,'Telegram intake worker',
      'Telegram ticket intake exhausted its embedding retries'
    );
  END IF;
  RETURN QUERY SELECT v_job.status='failed',v_job.chat_id,v_job.attempts;
END;
$$;

CREATE OR REPLACE FUNCTION ingest_telegram_ticket(
  p_source_event_id text,
  p_text text,
  p_received_at timestamptz,
  p_embedding vector(768),
  p_embedding_model text,
  p_workflow_version text,
  p_chat_id bigint,
  p_actor_user_id bigint
)
RETURNS TABLE (ticket_id uuid, cluster_id uuid, disposition text, similarity real, review_required boolean)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_result record;
BEGIN
  SELECT * INTO v_result FROM ingest_ticket(
    p_source_event_id,p_text,p_received_at,p_embedding,p_embedding_model,
    0.85,3,3,p_workflow_version
  );
  UPDATE tickets
  SET source='telegram',metadata=metadata||jsonb_build_object(
    'telegram_chat_id',p_chat_id::text,
    'telegram_user_id',p_actor_user_id::text
  ) WHERE id=v_result.ticket_id;
  UPDATE telegram_ticket_sessions
  SET state='open',version=version+1,ticket_id=v_result.ticket_id,
      opened_at=coalesce(opened_at,now()),updated_at=now()
  WHERE chat_id=p_chat_id AND telegram_user_id=p_actor_user_id;
  RETURN QUERY SELECT v_result.ticket_id,v_result.cluster_id,v_result.disposition,v_result.similarity,v_result.review_required;
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_report_delivery(p_report_draft_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_channel text;
DECLARE v_destination text;
BEGIN
  SELECT delivery_channel INTO v_channel FROM cluster_report_drafts WHERE id=p_report_draft_id;
  IF v_channel IS NULL THEN RAISE EXCEPTION 'unknown report draft'; END IF;
  IF v_channel='telegram' THEN
    SELECT chat_id::text INTO v_destination FROM telegram_connections
    WHERE role='engineering' AND active;
    IF v_destination IS NULL THEN RAISE EXCEPTION 'Telegram engineering group is not connected'; END IF;
  END IF;

  INSERT INTO delivery_attempts (report_draft_id,target,destination_ref)
  VALUES
    (p_report_draft_id,'google_doc',NULL),
    (p_report_draft_id,'google_sheets',NULL),
    (p_report_draft_id,CASE v_channel WHEN 'telegram' THEN 'eng_telegram' ELSE 'eng_slack' END,v_destination)
  ON CONFLICT (report_draft_id,target) DO NOTHING;
END;
$$;

DROP FUNCTION IF EXISTS claim_delivery_attempt(uuid,integer);
CREATE FUNCTION claim_delivery_attempt(
  p_report_draft_id uuid DEFAULT NULL,
  p_max_attempts integer DEFAULT 5
)
RETURNS TABLE (
  attempt_id uuid,
  report_draft_id uuid,
  target text,
  destination_ref text,
  attempt_number integer,
  cluster_id uuid,
  summary text,
  suspected_root_cause text,
  impact text,
  evidence jsonb,
  recommended_next_step text,
  google_doc_id text,
  google_doc_url text,
  delivery_channel text
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_attempt delivery_attempts%ROWTYPE;
BEGIN
  UPDATE delivery_attempts a
  SET status=CASE WHEN a.target='google_doc' THEN 'failed' ELSE 'retryable' END,
      locked_at=NULL,next_attempt_at=now(),
      last_error=coalesce(a.last_error,CASE WHEN a.target='google_doc'
        THEN 'worker lease expired after a Google Doc call; reconcile before retrying'
        ELSE 'worker lease expired before checkpoint' END),updated_at=now()
  WHERE a.status='processing' AND a.locked_at<now()-interval '15 minutes';

  SELECT a.* INTO v_attempt FROM delivery_attempts a
  WHERE a.status IN ('pending','retryable') AND a.next_attempt_at<=now()
    AND a.attempts<p_max_attempts
    AND (p_report_draft_id IS NULL OR a.report_draft_id=p_report_draft_id)
    AND (
      a.target='google_doc'
      OR (a.target='google_sheets' AND EXISTS (
        SELECT 1 FROM delivery_attempts d WHERE d.report_draft_id=a.report_draft_id AND d.target='google_doc' AND d.status='succeeded'))
      OR (a.target IN ('eng_slack','eng_telegram') AND EXISTS (
        SELECT 1 FROM delivery_attempts d WHERE d.report_draft_id=a.report_draft_id AND d.target='google_sheets' AND d.status='succeeded'))
    )
  ORDER BY a.created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE delivery_attempts SET status='processing',attempts=attempts+1,locked_at=now(),updated_at=now()
  WHERE id=v_attempt.id;

  RETURN QUERY SELECT a.id,d.id,a.target,a.destination_ref,a.attempts,d.cluster_id,
    d.summary,d.suspected_root_cause,d.impact,d.evidence,d.recommended_next_step,
    d.google_doc_id,d.google_doc_url,d.delivery_channel
  FROM delivery_attempts a JOIN cluster_report_drafts d ON d.id=a.report_draft_id
  WHERE a.id=v_attempt.id;
END;
$$;

CREATE OR REPLACE FUNCTION finalize_report_delivery(p_report_draft_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_cluster_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1 FROM delivery_attempts WHERE report_draft_id=p_report_draft_id
    GROUP BY report_draft_id HAVING count(*)=3 AND bool_and(status='succeeded')
  ) THEN
    UPDATE cluster_report_drafts SET status='delivered',updated_at=now()
    WHERE id=p_report_draft_id RETURNING cluster_id INTO v_cluster_id;
    UPDATE clusters SET status='alerted',alerted_at=coalesce(alerted_at,now()),updated_at=now()
    WHERE id=v_cluster_id AND status='approved';
    RETURN true;
  END IF;
  RETURN false;
END;
$$;
