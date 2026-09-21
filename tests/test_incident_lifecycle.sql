-- Transactional checks for migration 011. Run only against an isolated database.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_embedding vector(768) := array_prepend(1::real, array_fill(0::real, ARRAY[767]))::vector;
  v_ticket_id uuid;
  v_attention_cluster_id uuid;
  v_stuck_cluster_id uuid;
BEGIN
  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('incident-lifecycle-attention-seed', 'Synthetic low-confidence verification test', 'incident-lifecycle-test', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    status, updated_at
  ) VALUES (
    v_ticket_id, 'incident-lifecycle-test', v_embedding, v_embedding,
    'needs_review', now() - interval '30 minutes'
  ) RETURNING id INTO v_attention_cluster_id;
  INSERT INTO cluster_verifications (
    cluster_id, model, verdict, confidence, root_cause, evidence_ticket_ids, response
  ) VALUES (
    v_attention_cluster_id, 'test-model', 'needs_review', 0.3,
    'Insufficient evidence', ARRAY[v_ticket_id], '{"test":true}'::jsonb
  );

  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('incident-lifecycle-stuck-seed', 'Synthetic genuinely stuck verification test', 'incident-lifecycle-test', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    status, updated_at
  ) VALUES (
    v_ticket_id, 'incident-lifecycle-test', v_embedding, v_embedding,
    'verification_pending', now() - interval '30 minutes'
  ) RETURNING id INTO v_stuck_cluster_id;

  PERFORM * FROM refresh_operational_incidents(interval '15 minutes', interval '24 hours');

  IF NOT EXISTS (
    SELECT 1 FROM operational_incidents
    WHERE incident_key = 'verification:' || v_attention_cluster_id::text
      AND kind = 'verification_attention' AND severity = 'warning' AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'valid needs_review result was not surfaced as a warning';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM operational_incidents
    WHERE incident_key = 'verification:' || v_stuck_cluster_id::text
      AND kind = 'verification_stuck' AND severity = 'error' AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'genuinely stuck verification was not surfaced as an error';
  END IF;

  UPDATE clusters SET status = 'rejected', updated_at = now()
  WHERE id IN (v_attention_cluster_id, v_stuck_cluster_id);
  PERFORM * FROM refresh_operational_incidents(interval '15 minutes', interval '24 hours');

  IF EXISTS (
    SELECT 1 FROM operational_incidents
    WHERE incident_key IN (
      'verification:' || v_attention_cluster_id::text,
      'verification:' || v_stuck_cluster_id::text
    ) AND status <> 'resolved'
  ) THEN
    RAISE EXCEPTION 'cleared verification conditions did not resolve their incidents';
  END IF;
END;
$$;

SELECT 'PASS: needs-review warnings, true stuck errors, and automatic resolution verified' AS result;
ROLLBACK;
