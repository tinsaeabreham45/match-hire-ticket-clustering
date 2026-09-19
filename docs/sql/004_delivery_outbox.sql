-- Durable, ordered delivery for approved reports.
-- Apply after 001-003. This migration is forward-only and contains no secrets.

SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_draft_id uuid NOT NULL REFERENCES cluster_report_drafts(id) ON DELETE CASCADE,
  target text NOT NULL CHECK (target IN ('google_doc', 'google_sheets', 'eng_slack')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'retryable', 'succeeded', 'failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz,
  succeeded_at timestamptz,
  external_id text,
  external_url text,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (report_draft_id, target)
);

CREATE INDEX IF NOT EXISTS delivery_attempts_due_idx
  ON delivery_attempts (status, next_attempt_at)
  WHERE status IN ('pending', 'retryable');

CREATE OR REPLACE FUNCTION enqueue_report_delivery(p_report_draft_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  INSERT INTO delivery_attempts (report_draft_id, target)
  VALUES
    (p_report_draft_id, 'google_doc'),
    (p_report_draft_id, 'google_sheets'),
    (p_report_draft_id, 'eng_slack')
  ON CONFLICT (report_draft_id, target) DO NOTHING;
END;
$$;

-- Claims only the next ordered stage. SKIP LOCKED allows multiple workers
-- without two workers delivering the same report stage.
CREATE OR REPLACE FUNCTION claim_delivery_attempt(
  p_report_draft_id uuid DEFAULT NULL,
  p_max_attempts integer DEFAULT 5
)
RETURNS TABLE (
  attempt_id uuid,
  report_draft_id uuid,
  target text,
  attempt_number integer,
  summary text,
  suspected_root_cause text,
  impact text,
  evidence jsonb,
  recommended_next_step text,
  google_doc_id text,
  google_doc_url text
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_attempt delivery_attempts%ROWTYPE;
BEGIN
  -- A worker may die after an external call but before it writes a checkpoint.
  -- Do not immediately repeat the call. A Google Doc create is non-idempotent,
  -- so it stops for operator reconciliation; the other stages can retry.
  UPDATE delivery_attempts
  SET status = CASE WHEN target = 'google_doc' THEN 'failed' ELSE 'retryable' END,
      locked_at = NULL, next_attempt_at = now(),
      last_error = coalesce(last_error, CASE WHEN target = 'google_doc'
        THEN 'worker lease expired after a Google Doc call; reconcile before retrying'
        ELSE 'worker lease expired before checkpoint' END),
      updated_at = now()
  WHERE status = 'processing' AND locked_at < now() - interval '15 minutes';

  SELECT a.* INTO v_attempt
  FROM delivery_attempts a
  WHERE a.status IN ('pending', 'retryable')
    AND a.next_attempt_at <= now()
    AND a.attempts < p_max_attempts
    AND (p_report_draft_id IS NULL OR a.report_draft_id = p_report_draft_id)
    AND (
      a.target = 'google_doc'
      OR (a.target = 'google_sheets' AND EXISTS (
        SELECT 1 FROM delivery_attempts d
        WHERE d.report_draft_id = a.report_draft_id AND d.target = 'google_doc' AND d.status = 'succeeded'
      ))
      OR (a.target = 'eng_slack' AND EXISTS (
        SELECT 1 FROM delivery_attempts d
        WHERE d.report_draft_id = a.report_draft_id AND d.target = 'google_sheets' AND d.status = 'succeeded'
      ))
    )
  ORDER BY a.created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;

  UPDATE delivery_attempts
  SET status = 'processing', attempts = attempts + 1, locked_at = now(), updated_at = now()
  WHERE id = v_attempt.id;

  RETURN QUERY
  SELECT a.id, d.id, a.target, a.attempts,
         d.summary, d.suspected_root_cause, d.impact, d.evidence, d.recommended_next_step,
         d.google_doc_id, d.google_doc_url
  FROM delivery_attempts a
  JOIN cluster_report_drafts d ON d.id = a.report_draft_id
  WHERE a.id = v_attempt.id;
END;
$$;

-- Use only after checking the external target. This intentionally makes a
-- failed stage eligible for a controlled retry; it never runs automatically.
CREATE OR REPLACE FUNCTION requeue_delivery_attempt(p_attempt_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  UPDATE delivery_attempts
  SET status = 'retryable', locked_at = NULL, next_attempt_at = now(), updated_at = now()
  WHERE id = p_attempt_id AND status = 'failed';

  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt is not failed'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION complete_delivery_attempt(
  p_attempt_id uuid,
  p_external_id text DEFAULT NULL,
  p_external_url text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_report_draft_id uuid;
DECLARE v_target text;
BEGIN
  UPDATE delivery_attempts
  SET status = 'succeeded', succeeded_at = now(), locked_at = NULL,
      external_id = coalesce(p_external_id, external_id),
      external_url = coalesce(p_external_url, external_url),
      last_error = NULL, updated_at = now()
  WHERE id = p_attempt_id AND status = 'processing'
  RETURNING report_draft_id, target INTO v_report_draft_id, v_target;

  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt is not claimable'; END IF;

  IF v_target = 'google_doc' THEN
    UPDATE cluster_report_drafts
    SET google_doc_id = p_external_id, google_doc_url = p_external_url, updated_at = now()
    WHERE id = v_report_draft_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fail_delivery_attempt(
  p_attempt_id uuid,
  p_error text,
  p_retry_delay interval DEFAULT interval '5 minutes',
  p_max_attempts integer DEFAULT 5
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
BEGIN
  UPDATE delivery_attempts
  SET status = CASE WHEN attempts >= p_max_attempts THEN 'failed' ELSE 'retryable' END,
      locked_at = NULL,
      next_attempt_at = CASE WHEN attempts >= p_max_attempts THEN next_attempt_at ELSE now() + p_retry_delay END,
      last_error = left(coalesce(p_error, 'unknown delivery failure'), 2000),
      updated_at = now()
  WHERE id = p_attempt_id AND status = 'processing';

  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt is not processing'; END IF;
END;
$$;

-- The report and cluster become delivered/alerted only after all three targets
-- have confirmed success. Calling it earlier is harmless and returns false.
CREATE OR REPLACE FUNCTION finalize_report_delivery(p_report_draft_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_cluster_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1 FROM delivery_attempts
    WHERE report_draft_id = p_report_draft_id
    GROUP BY report_draft_id
    HAVING count(*) = 3 AND bool_and(status = 'succeeded')
  ) THEN
    UPDATE cluster_report_drafts
    SET status = 'delivered', updated_at = now()
    WHERE id = p_report_draft_id
    RETURNING cluster_id INTO v_cluster_id;

    UPDATE clusters
    SET status = 'alerted', alerted_at = coalesce(alerted_at, now()), updated_at = now()
    WHERE id = v_cluster_id AND status = 'approved';
    RETURN true;
  END IF;
  RETURN false;
END;
$$;
