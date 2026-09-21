-- Close legacy review bypasses and surface verification work that stops before
-- a human-review draft exists. Apply after 001-009.

SET search_path TO ticket_cluster, public;

DROP FUNCTION IF EXISTS record_review_action(uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION record_cluster_verification(
  p_cluster_id uuid,
  p_model text,
  p_verdict text,
  p_confidence real,
  p_root_cause text,
  p_evidence_ticket_ids uuid[],
  p_response jsonb,
  p_confidence_threshold real DEFAULT 0.75
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_current_status text;
  v_status text;
BEGIN
  IF p_verdict NOT IN ('verified', 'rejected', 'needs_review') OR p_response IS NULL THEN
    RAISE EXCEPTION 'invalid structured verification result';
  END IF;

  SELECT status INTO v_current_status
  FROM clusters
  WHERE id = p_cluster_id
  FOR UPDATE;

  IF v_current_status IS NULL THEN
    RAISE EXCEPTION 'unknown cluster';
  END IF;
  IF v_current_status <> 'verification_pending' THEN
    RETURN 'ignored_wrong_state';
  END IF;

  INSERT INTO cluster_verifications (
    cluster_id, model, verdict, confidence, root_cause,
    evidence_ticket_ids, response
  ) VALUES (
    p_cluster_id, p_model, p_verdict, p_confidence, p_root_cause,
    p_evidence_ticket_ids, p_response
  );

  v_status := CASE
    WHEN p_verdict = 'verified' AND p_confidence >= p_confidence_threshold THEN 'pending_review'
    ELSE 'needs_review'
  END;
  UPDATE clusters SET status = v_status, updated_at = now() WHERE id = p_cluster_id;
  RETURN v_status;
END;
$$;

ALTER TABLE operational_incidents
  DROP CONSTRAINT IF EXISTS operational_incidents_kind_check;
ALTER TABLE operational_incidents
  ADD CONSTRAINT operational_incidents_kind_check
  CHECK (kind IN (
    'delivery_stuck', 'delivery_failed', 'review_overdue',
    'verification_stuck', 'workflow_failure'
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

    SELECT
      'review:' || d.id::text,
      'review_overdue',
      'warning',
      d.id::text,
      'Root-cause review is waiting for a human decision',
      jsonb_build_object('cluster_id', d.cluster_id, 'age_hours', round(extract(epoch FROM now() - d.created_at) / 3600, 1))
    FROM cluster_report_drafts d
    WHERE d.status = 'pending_review' AND d.created_at < now() - p_review_after

    UNION ALL

    SELECT
      'verification:' || c.id::text,
      'verification_stuck',
      'error',
      c.id::text,
      'Cluster verification stopped before a human-review draft was created',
      jsonb_build_object(
        'cluster_status', c.status,
        'age_minutes', round(extract(epoch FROM now() - c.updated_at) / 60, 1)
      )
    FROM clusters c
    WHERE c.status IN ('verification_pending', 'needs_review')
      AND c.updated_at < now() - p_stuck_after
      AND NOT EXISTS (
        SELECT 1 FROM cluster_report_drafts d WHERE d.cluster_id = c.id
      )
  ), upserted AS (
    INSERT INTO operational_incidents (
      incident_key, kind, severity, reference_id, message, context
    )
    SELECT c.incident_key, c.kind, c.severity, c.reference_id, c.message, c.context FROM candidates c
    ON CONFLICT ON CONSTRAINT operational_incidents_pkey DO UPDATE
      SET kind = EXCLUDED.kind,
          severity = EXCLUDED.severity,
          status = CASE
            WHEN operational_incidents.status = 'resolved' THEN 'open'
            ELSE operational_incidents.status
          END,
          notified_at = CASE
            WHEN operational_incidents.status = 'resolved' THEN NULL
            ELSE operational_incidents.notified_at
          END,
          last_seen_at = now(), message = EXCLUDED.message, context = EXCLUDED.context
    RETURNING operational_incidents.incident_key, operational_incidents.kind,
              operational_incidents.severity, operational_incidents.message
  )
  SELECT * FROM upserted;
END;
$$;
