-- Human investigation queue for valid low-confidence verification outcomes.
-- Apply after 001-011. These actions never enqueue engineering delivery.

SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS cluster_investigations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  verification_id uuid NOT NULL REFERENCES cluster_verifications(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'retry_requested', 'dismissed', 'split')),
  model text NOT NULL,
  verdict text NOT NULL,
  confidence real NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  reason text NOT NULL,
  evidence_ticket_ids uuid[] NOT NULL DEFAULT '{}',
  slack_channel_id text,
  slack_message_ts text,
  notified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS cluster_investigations_one_open_idx
  ON cluster_investigations (cluster_id) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS investigation_action_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  callback_id text NOT NULL UNIQUE,
  investigation_id uuid,
  cluster_id uuid,
  action text,
  actor_id text,
  workspace_id text,
  channel_id text,
  outcome text NOT NULL,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cluster_investigation_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  investigation_id uuid NOT NULL REFERENCES cluster_investigations(id) ON DELETE CASCADE,
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('retry', 'dismiss', 'split')),
  actor_id text NOT NULL,
  callback_id text NOT NULL UNIQUE,
  workspace_id text NOT NULL,
  channel_id text NOT NULL,
  acted_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION create_cluster_investigation(p_cluster_id uuid)
RETURNS TABLE (
  investigation_id uuid,
  verification_id uuid,
  model text,
  verdict text,
  confidence real,
  reason text,
  evidence_ticket_ids uuid[],
  should_notify boolean
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_cluster clusters%ROWTYPE;
  v_verification cluster_verifications%ROWTYPE;
  v_investigation cluster_investigations%ROWTYPE;
BEGIN
  SELECT * INTO v_cluster FROM clusters WHERE id = p_cluster_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cluster'; END IF;
  IF v_cluster.status <> 'needs_review' THEN
    RAISE EXCEPTION 'cluster is not waiting for investigation';
  END IF;

  SELECT * INTO v_investigation
  FROM cluster_investigations
  WHERE cluster_id = p_cluster_id AND status = 'open'
  FOR UPDATE;

  IF FOUND THEN
    RETURN QUERY SELECT
      v_investigation.id,
      v_investigation.verification_id,
      v_investigation.model,
      v_investigation.verdict,
      v_investigation.confidence,
      v_investigation.reason,
      v_investigation.evidence_ticket_ids,
      v_investigation.notified_at IS NULL;
    RETURN;
  END IF;

  SELECT * INTO v_verification
  FROM cluster_verifications
  WHERE cluster_id = p_cluster_id
  ORDER BY created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'cluster has no verification result'; END IF;

  INSERT INTO cluster_investigations (
    cluster_id, verification_id, model, verdict, confidence,
    reason, evidence_ticket_ids
  ) VALUES (
    p_cluster_id, v_verification.id, v_verification.model,
    v_verification.verdict, v_verification.confidence,
    coalesce(nullif(v_verification.root_cause, ''), 'Insufficient evidence to confirm one root cause'),
    v_verification.evidence_ticket_ids
  ) RETURNING * INTO v_investigation;

  RETURN QUERY SELECT
    v_investigation.id,
    v_investigation.verification_id,
    v_investigation.model,
    v_investigation.verdict,
    v_investigation.confidence,
    v_investigation.reason,
    v_investigation.evidence_ticket_ids,
    true;
END;
$$;

CREATE OR REPLACE FUNCTION mark_investigation_notified(
  p_investigation_id uuid,
  p_slack_channel_id text,
  p_slack_message_ts text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  IF coalesce(nullif(p_slack_channel_id, ''), null) IS NULL
     OR coalesce(nullif(p_slack_message_ts, ''), null) IS NULL THEN
    RAISE EXCEPTION 'Slack channel and message timestamp are required';
  END IF;

  UPDATE cluster_investigations
  SET slack_channel_id = p_slack_channel_id,
      slack_message_ts = p_slack_message_ts,
      notified_at = now(),
      updated_at = now()
  WHERE id = p_investigation_id AND status = 'open';
  IF NOT FOUND THEN RAISE EXCEPTION 'open investigation not found'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION record_investigation_decision(
  p_cluster_id uuid,
  p_investigation_id uuid,
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
DECLARE
  v_cluster clusters%ROWTYPE;
  v_investigation cluster_investigations%ROWTYPE;
  v_outcome text;
BEGIN
  INSERT INTO investigation_action_attempts (
    callback_id, investigation_id, cluster_id, action, actor_id,
    workspace_id, channel_id, outcome
  ) VALUES (
    p_callback_id, p_investigation_id, p_cluster_id, p_action, p_actor_id,
    p_workspace_id, p_channel_id, 'received'
  ) ON CONFLICT (callback_id) DO NOTHING;
  IF NOT FOUND THEN RETURN 'duplicate_callback'; END IF;

  IF p_action NOT IN ('retry', 'dismiss', 'split') THEN
    UPDATE investigation_action_attempts SET outcome = 'denied_invalid_action', detail = 'unsupported action' WHERE callback_id = p_callback_id;
    RETURN 'denied_invalid_action';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM authorized_approvers WHERE slack_user_id = p_actor_id AND active) THEN
    UPDATE investigation_action_attempts SET outcome = 'denied_not_authorized', detail = 'actor is not an active approver' WHERE callback_id = p_callback_id;
    RETURN 'denied_not_authorized';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM authorized_review_contexts
    WHERE slack_workspace_id = p_workspace_id AND slack_channel_id = p_channel_id AND active
  ) THEN
    UPDATE investigation_action_attempts SET outcome = 'denied_unexpected_context', detail = 'workspace or channel is not authorized' WHERE callback_id = p_callback_id;
    RETURN 'denied_unexpected_context';
  END IF;

  SELECT * INTO v_investigation
  FROM cluster_investigations WHERE id = p_investigation_id FOR UPDATE;
  IF NOT FOUND OR v_investigation.cluster_id <> p_cluster_id THEN
    UPDATE investigation_action_attempts SET outcome = 'ignored_investigation_mismatch' WHERE callback_id = p_callback_id;
    RETURN 'ignored_investigation_mismatch';
  END IF;

  SELECT * INTO v_cluster FROM clusters WHERE id = p_cluster_id FOR UPDATE;
  IF NOT FOUND THEN
    UPDATE investigation_action_attempts SET outcome = 'ignored_unknown_cluster' WHERE callback_id = p_callback_id;
    RETURN 'ignored_unknown_cluster';
  END IF;
  IF v_investigation.status <> 'open' OR v_cluster.status <> 'needs_review' THEN
    UPDATE investigation_action_attempts SET outcome = 'ignored_not_open' WHERE callback_id = p_callback_id;
    RETURN 'ignored_not_open';
  END IF;

  IF p_action = 'retry' THEN
    UPDATE cluster_investigations SET status = 'retry_requested', updated_at = now() WHERE id = p_investigation_id;
    UPDATE clusters SET status = 'verification_pending', updated_at = now() WHERE id = p_cluster_id;
    v_outcome := 'retry_queued';
  ELSIF p_action = 'dismiss' THEN
    UPDATE cluster_investigations SET status = 'dismissed', updated_at = now() WHERE id = p_investigation_id;
    UPDATE clusters SET status = 'rejected', updated_at = now() WHERE id = p_cluster_id;
    v_outcome := 'dismissed';
  ELSE
    UPDATE cluster_investigations SET status = 'split', updated_at = now() WHERE id = p_investigation_id;
    UPDATE clusters SET status = 'split', updated_at = now() WHERE id = p_cluster_id;
    v_outcome := 'split';
  END IF;

  INSERT INTO cluster_investigation_actions (
    investigation_id, cluster_id, action, actor_id, callback_id,
    workspace_id, channel_id
  ) VALUES (
    p_investigation_id, p_cluster_id, p_action, p_actor_id, p_callback_id,
    p_workspace_id, p_channel_id
  );
  UPDATE investigation_action_attempts SET outcome = v_outcome WHERE callback_id = p_callback_id;
  UPDATE operational_incidents
  SET status = 'resolved', last_seen_at = now()
  WHERE incident_key = 'verification:' || p_cluster_id::text
    AND status IN ('open', 'acknowledged');
  RETURN v_outcome;
END;
$$;

ALTER TABLE operational_incidents
  DROP CONSTRAINT IF EXISTS operational_incidents_kind_check;
ALTER TABLE operational_incidents
  ADD CONSTRAINT operational_incidents_kind_check
  CHECK (kind IN (
    'delivery_stuck', 'delivery_failed', 'review_overdue',
    'verification_stuck', 'verification_attention',
    'investigation_delivery_stuck', 'workflow_failure'
  ));

CREATE OR REPLACE FUNCTION refresh_operational_incidents(
  p_stuck_after interval DEFAULT interval '15 minutes',
  p_review_after interval DEFAULT interval '24 hours'
)
RETURNS TABLE (incident_key text, kind text, severity text, message text)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT
      'delivery:' || a.id::text AS incident_key,
      CASE WHEN a.status = 'failed' THEN 'delivery_failed' ELSE 'delivery_stuck' END AS kind,
      CASE WHEN a.status = 'failed' THEN 'error' ELSE 'warning' END AS severity,
      a.id::text AS reference_id,
      CASE WHEN a.status = 'failed'
        THEN 'Delivery attempt exhausted or requires reconciliation: ' || a.target
        ELSE 'Delivery attempt lease is overdue: ' || a.target
      END AS message,
      jsonb_build_object('report_draft_id', a.report_draft_id, 'target', a.target, 'attempts', a.attempts) AS context
    FROM delivery_attempts a
    WHERE a.status = 'failed'
       OR (a.status = 'processing' AND a.locked_at < now() - p_stuck_after)

    UNION ALL
    SELECT 'review:' || d.id::text, 'review_overdue', 'warning', d.id::text,
      'Root-cause review is waiting for a human decision',
      jsonb_build_object('cluster_id', d.cluster_id, 'age_hours', round(extract(epoch FROM now() - d.created_at) / 3600, 1))
    FROM cluster_report_drafts d
    WHERE d.status = 'pending_review' AND d.created_at < now() - p_review_after

    UNION ALL
    SELECT 'verification:' || c.id::text, 'verification_stuck', 'error', c.id::text,
      'Cluster verification did not reach a recorded model decision',
      jsonb_build_object('cluster_status', c.status, 'age_minutes', round(extract(epoch FROM now() - c.updated_at) / 60, 1))
    FROM clusters c
    WHERE c.status = 'verification_pending'
      AND c.updated_at < now() - p_stuck_after

    UNION ALL
    SELECT
      'verification:' || c.id::text,
      CASE WHEN i.id IS NULL THEN 'verification_attention' ELSE 'investigation_delivery_stuck' END,
      CASE WHEN i.id IS NULL THEN 'warning' ELSE 'error' END,
      c.id::text,
      CASE WHEN i.id IS NULL
        THEN 'AI verification could not confirm one root cause; operator investigation is required'
        ELSE 'Investigation card was not confirmed in Slack'
      END,
      jsonb_build_object(
        'cluster_status', c.status,
        'age_minutes', round(extract(epoch FROM now() - c.updated_at) / 60, 1),
        'investigation_id', i.id,
        'latest_verdict', v.verdict,
        'latest_confidence', v.confidence
      )
    FROM clusters c
    LEFT JOIN LATERAL (
      SELECT ci.id, ci.notified_at
      FROM cluster_investigations ci
      WHERE ci.cluster_id = c.id AND ci.status = 'open'
      ORDER BY ci.created_at DESC LIMIT 1
    ) i ON true
    LEFT JOIN LATERAL (
      SELECT cv.verdict, cv.confidence
      FROM cluster_verifications cv
      WHERE cv.cluster_id = c.id
      ORDER BY cv.created_at DESC LIMIT 1
    ) v ON true
    WHERE c.status = 'needs_review'
      AND c.updated_at < now() - p_stuck_after
      AND (i.id IS NULL OR i.notified_at IS NULL)
  ), resolved AS (
    UPDATE operational_incidents oi
    SET status = 'resolved', last_seen_at = now()
    WHERE oi.kind IN (
      'delivery_stuck', 'delivery_failed', 'review_overdue',
      'verification_stuck', 'verification_attention', 'investigation_delivery_stuck'
    )
      AND oi.status IN ('open', 'acknowledged')
      AND NOT EXISTS (SELECT 1 FROM candidates c WHERE c.incident_key = oi.incident_key)
    RETURNING oi.incident_key
  ), upserted AS (
    INSERT INTO operational_incidents (
      incident_key, kind, severity, reference_id, message, context
    )
    SELECT c.incident_key, c.kind, c.severity, c.reference_id, c.message, c.context FROM candidates c
    ON CONFLICT ON CONSTRAINT operational_incidents_pkey DO UPDATE
      SET kind = EXCLUDED.kind,
          severity = EXCLUDED.severity,
          status = CASE WHEN operational_incidents.status = 'resolved' THEN 'open' ELSE operational_incidents.status END,
          notified_at = CASE WHEN operational_incidents.status = 'resolved' THEN NULL ELSE operational_incidents.notified_at END,
          last_seen_at = now(), message = EXCLUDED.message, context = EXCLUDED.context
    RETURNING operational_incidents.incident_key, operational_incidents.kind,
              operational_incidents.severity, operational_incidents.message
  )
  SELECT * FROM upserted;
END;
$$;
