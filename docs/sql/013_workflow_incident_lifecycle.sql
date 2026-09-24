-- Prevent one-off workflow execution failures from paging forever while
-- preserving repeated notification for conditions that remain actively stuck.
-- Apply after 001-012.

SET search_path TO ticket_cluster, public;

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
DECLARE
  v_key text := 'workflow:' || coalesce(nullif(p_execution_id, ''), gen_random_uuid()::text);
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
    SET last_seen_at = now(),
        message = EXCLUDED.message,
        context = EXCLUDED.context;
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
  SELECT oi.incident_key, oi.severity, oi.message, oi.context
  FROM operational_incidents oi
  WHERE oi.status = 'open'
    AND (
      oi.notified_at IS NULL
      OR (
        oi.severity = 'error'
        AND oi.kind IN (
          'delivery_stuck', 'delivery_failed',
          'verification_stuck', 'investigation_delivery_stuck'
        )
        AND oi.notified_at < now() - p_repeat_after
      )
    )
  ORDER BY CASE oi.severity WHEN 'error' THEN 0 ELSE 1 END, oi.first_seen_at
  LIMIT greatest(1, least(p_limit, 100));
$$;

CREATE OR REPLACE FUNCTION resolve_operational_incident(
  p_incident_key text,
  p_actor text,
  p_note text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  IF coalesce(btrim(p_note), '') = '' THEN
    RAISE EXCEPTION 'resolution note is required';
  END IF;

  UPDATE operational_incidents
  SET status = 'resolved',
      last_seen_at = now(),
      acknowledged_at = coalesce(acknowledged_at, now()),
      acknowledged_by = left(coalesce(nullif(p_actor, ''), 'operator'), 200),
      acknowledgement_note = left(p_note, 1000)
  WHERE incident_key = p_incident_key
    AND status IN ('open', 'acknowledged');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'open or acknowledged incident not found';
  END IF;
END;
$$;
