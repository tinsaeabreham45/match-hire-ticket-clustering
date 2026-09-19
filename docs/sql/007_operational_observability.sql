-- Operator-visible incident ledger for workflow and delivery failures.
-- Apply after 001-006. Stores no ticket body, credential, or model prompt.

SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS operational_incidents (
  incident_key text PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('delivery_stuck', 'delivery_failed', 'review_overdue', 'workflow_failure')),
  severity text NOT NULL CHECK (severity IN ('warning', 'error')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved')),
  reference_id text,
  message text NOT NULL,
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  notified_at timestamptz,
  acknowledged_at timestamptz,
  acknowledged_by text,
  acknowledgement_note text
);

CREATE INDEX IF NOT EXISTS operational_incidents_open_idx
  ON operational_incidents (status, severity, last_seen_at DESC)
  WHERE status IN ('open', 'acknowledged');

CREATE OR REPLACE FUNCTION record_workflow_failure(
  p_workflow_id text,
  p_execution_id text,
  p_node_name text,
  p_message text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_key text := 'workflow:' || coalesce(nullif(p_execution_id, ''), gen_random_uuid()::text);
BEGIN
  INSERT INTO operational_incidents (
    incident_key, kind, severity, reference_id, message, context
  ) VALUES (
    v_key,
    'workflow_failure',
    'error',
    p_execution_id,
    left(coalesce(nullif(p_message, ''), 'n8n workflow failed without an error message'), 1000),
    jsonb_build_object(
      'workflow_id', left(coalesce(p_workflow_id, ''), 200),
      'node_name', left(coalesce(p_node_name, ''), 200)
    )
  ) ON CONFLICT (incident_key) DO UPDATE
    SET severity = 'error', status = 'open', last_seen_at = now(),
        message = EXCLUDED.message, context = EXCLUDED.context,
        notified_at = NULL, acknowledged_at = NULL,
        acknowledged_by = NULL, acknowledgement_note = NULL;
END;
$$;

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

    SELECT
      'review:' || d.id::text,
      'review_overdue',
      'warning',
      d.id::text,
      'Approved review is waiting for a human decision',
      jsonb_build_object('cluster_id', d.cluster_id, 'age_hours', round(extract(epoch FROM now() - d.created_at) / 3600, 1))
    FROM cluster_report_drafts d
    WHERE d.status = 'pending_review' AND d.created_at < now() - p_review_after
  ), upserted AS (
    INSERT INTO operational_incidents (
      incident_key, kind, severity, reference_id, message, context
    )
    SELECT c.incident_key, c.kind, c.severity, c.reference_id, c.message, c.context FROM candidates c
    ON CONFLICT (incident_key) DO UPDATE
      SET kind = EXCLUDED.kind, severity = EXCLUDED.severity, status = 'open',
          last_seen_at = now(), message = EXCLUDED.message, context = EXCLUDED.context
    RETURNING operational_incidents.incident_key, operational_incidents.kind,
              operational_incidents.severity, operational_incidents.message
  )
  SELECT * FROM upserted;
END;
$$;

CREATE OR REPLACE FUNCTION list_operational_incidents_to_notify(
  p_repeat_after interval DEFAULT interval '60 minutes',
  p_limit integer DEFAULT 20
)
RETURNS TABLE (incident_key text, severity text, message text, context jsonb)
LANGUAGE sql
STABLE
SET search_path = ticket_cluster, public
AS $$
  SELECT incident_key, severity, message, context
  FROM operational_incidents
  WHERE status = 'open'
    AND (notified_at IS NULL OR notified_at < now() - p_repeat_after)
  ORDER BY CASE severity WHEN 'error' THEN 0 ELSE 1 END, first_seen_at
  LIMIT greatest(1, least(p_limit, 100));
$$;

CREATE OR REPLACE FUNCTION mark_operational_incidents_notified(p_incident_keys text[])
RETURNS integer
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_count integer;
BEGIN
  UPDATE operational_incidents
  SET notified_at = now()
  WHERE incident_key = ANY(p_incident_keys) AND status = 'open';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION acknowledge_operational_incident(
  p_incident_key text,
  p_actor text,
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  UPDATE operational_incidents
  SET status = 'acknowledged', acknowledged_at = now(),
      acknowledged_by = left(coalesce(nullif(p_actor, ''), 'operator'), 200),
      acknowledgement_note = left(coalesce(p_note, ''), 1000)
  WHERE incident_key = p_incident_key AND status = 'open';

  IF NOT FOUND THEN RAISE EXCEPTION 'open incident not found'; END IF;
END;
$$;
