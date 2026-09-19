-- Authorized, atomic Slack review decisions.
-- Apply after 004_delivery_outbox.sql.

SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS authorized_approvers (
  slack_user_id text PRIMARY KEY,
  active boolean NOT NULL DEFAULT true,
  added_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS authorized_review_contexts (
  slack_workspace_id text NOT NULL,
  slack_channel_id text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (slack_workspace_id, slack_channel_id)
);

CREATE TABLE IF NOT EXISTS review_action_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  callback_id text NOT NULL UNIQUE,
  cluster_id uuid,
  report_draft_id uuid,
  action text,
  actor_id text,
  workspace_id text,
  channel_id text,
  outcome text NOT NULL,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE cluster_review_actions
  ADD COLUMN IF NOT EXISTS report_draft_id uuid REFERENCES cluster_report_drafts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS workspace_id text,
  ADD COLUMN IF NOT EXISTS channel_id text;

-- Add the support lead after deployment using their Slack member ID:
-- INSERT INTO ticket_cluster.authorized_approvers (slack_user_id) VALUES ('REPLACE_WITH_SUPPORT_LEAD_SLACK_USER_ID');
-- INSERT INTO ticket_cluster.authorized_review_contexts (slack_workspace_id, slack_channel_id)
-- VALUES ('REPLACE_WITH_SLACK_WORKSPACE_ID', 'REPLACE_WITH_SUPPORT_TRIAGE_CHANNEL_ID');

CREATE OR REPLACE FUNCTION record_review_decision(
  p_cluster_id uuid,
  p_report_draft_id uuid,
  p_action text,
  p_actor_id text,
  p_callback_id text,
  p_workspace_id text,
  p_channel_id text
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_cluster clusters%ROWTYPE;
DECLARE v_draft cluster_report_drafts%ROWTYPE;
DECLARE v_outcome text;
BEGIN
  INSERT INTO review_action_attempts (
    callback_id, cluster_id, report_draft_id, action, actor_id, workspace_id, channel_id, outcome
  ) VALUES (
    p_callback_id, p_cluster_id, p_report_draft_id, p_action, p_actor_id, p_workspace_id, p_channel_id, 'received'
  ) ON CONFLICT (callback_id) DO NOTHING;

  IF NOT FOUND THEN RETURN 'duplicate_callback'; END IF;

  IF p_action NOT IN ('approve', 'reject', 'split') THEN
    UPDATE review_action_attempts SET outcome = 'denied_invalid_action', detail = 'unsupported action' WHERE callback_id = p_callback_id;
    RETURN 'denied_invalid_action';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM authorized_approvers WHERE slack_user_id = p_actor_id AND active) THEN
    UPDATE review_action_attempts SET outcome = 'denied_not_authorized', detail = 'actor is not an active approver' WHERE callback_id = p_callback_id;
    RETURN 'denied_not_authorized';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM authorized_review_contexts
    WHERE slack_workspace_id = p_workspace_id AND slack_channel_id = p_channel_id AND active
  ) THEN
    UPDATE review_action_attempts SET outcome = 'denied_unexpected_context', detail = 'workspace or channel is not authorized for review' WHERE callback_id = p_callback_id;
    RETURN 'denied_unexpected_context';
  END IF;

  SELECT * INTO v_draft FROM cluster_report_drafts WHERE id = p_report_draft_id FOR UPDATE;
  IF NOT FOUND OR v_draft.cluster_id <> p_cluster_id THEN
    UPDATE review_action_attempts SET outcome = 'ignored_draft_mismatch', detail = 'draft is missing or belongs to another cluster' WHERE callback_id = p_callback_id;
    RETURN 'ignored_draft_mismatch';
  END IF;

  SELECT * INTO v_cluster FROM clusters WHERE id = p_cluster_id FOR UPDATE;
  IF NOT FOUND THEN
    UPDATE review_action_attempts SET outcome = 'ignored_unknown_cluster' WHERE callback_id = p_callback_id;
    RETURN 'ignored_unknown_cluster';
  END IF;

  IF v_cluster.status <> 'pending_review' OR v_draft.status <> 'pending_review' THEN
    UPDATE review_action_attempts SET outcome = 'ignored_not_pending', detail = 'cluster or draft is no longer pending review' WHERE callback_id = p_callback_id;
    RETURN 'ignored_not_pending';
  END IF;

  IF p_action = 'approve' THEN
    UPDATE clusters SET status = 'approved', updated_at = now() WHERE id = p_cluster_id;
    UPDATE cluster_report_drafts SET status = 'delivery_pending', updated_at = now() WHERE id = p_report_draft_id;
    PERFORM enqueue_report_delivery(p_report_draft_id);
    v_outcome := 'delivery_queued';
  ELSE
    UPDATE clusters SET status = CASE WHEN p_action = 'reject' THEN 'rejected' ELSE 'split' END, updated_at = now() WHERE id = p_cluster_id;
    UPDATE cluster_report_drafts SET status = CASE WHEN p_action = 'reject' THEN 'rejected' ELSE 'split' END, updated_at = now() WHERE id = p_report_draft_id;
    v_outcome := CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'split' END;
  END IF;

  INSERT INTO cluster_review_actions (cluster_id, report_draft_id, action, actor_id, callback_id, workspace_id, channel_id)
  VALUES (p_cluster_id, p_report_draft_id, p_action, p_actor_id, p_callback_id, p_workspace_id, p_channel_id);
  UPDATE review_action_attempts SET outcome = v_outcome WHERE callback_id = p_callback_id;
  RETURN v_outcome;
END;
$$;
