-- Distinguish a genuinely stuck verification from a valid low-confidence
-- needs_review outcome, and resolve generated incidents when their condition clears.
-- Apply after 001-010.

SET search_path TO ticket_cluster, public;

ALTER TABLE operational_incidents
  DROP CONSTRAINT IF EXISTS operational_incidents_kind_check;
ALTER TABLE operational_incidents
  ADD CONSTRAINT operational_incidents_kind_check
  CHECK (kind IN (
    'delivery_stuck', 'delivery_failed', 'review_overdue',
    'verification_stuck', 'verification_attention', 'workflow_failure'
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
      'Cluster verification did not reach a recorded model decision',
      jsonb_build_object(
        'cluster_status', c.status,
        'age_minutes', round(extract(epoch FROM now() - c.updated_at) / 60, 1)
      )
    FROM clusters c
    WHERE c.status = 'verification_pending'
      AND c.updated_at < now() - p_stuck_after
      AND NOT EXISTS (
        SELECT 1 FROM cluster_report_drafts d WHERE d.cluster_id = c.id
      )

    UNION ALL

    SELECT
      'verification:' || c.id::text,
      'verification_attention',
      'warning',
      c.id::text,
      'AI verification could not confirm one root cause; operator investigation is required',
      jsonb_build_object(
        'cluster_status', c.status,
        'age_minutes', round(extract(epoch FROM now() - c.updated_at) / 60, 1),
        'latest_verdict', v.verdict,
        'latest_confidence', v.confidence
      )
    FROM clusters c
    LEFT JOIN LATERAL (
      SELECT cv.verdict, cv.confidence
      FROM cluster_verifications cv
      WHERE cv.cluster_id = c.id
      ORDER BY cv.created_at DESC
      LIMIT 1
    ) v ON true
    WHERE c.status = 'needs_review'
      AND c.updated_at < now() - p_stuck_after
      AND NOT EXISTS (
        SELECT 1 FROM cluster_report_drafts d WHERE d.cluster_id = c.id
      )
  ), resolved AS (
    UPDATE operational_incidents oi
    SET status = 'resolved', last_seen_at = now()
    WHERE oi.kind IN (
      'delivery_stuck', 'delivery_failed', 'review_overdue',
      'verification_stuck', 'verification_attention'
    )
      AND oi.status IN ('open', 'acknowledged')
      AND NOT EXISTS (
        SELECT 1 FROM candidates c WHERE c.incident_key = oi.incident_key
      )
    RETURNING oi.incident_key
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
