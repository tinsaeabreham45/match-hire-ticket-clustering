-- Transactional checks for migration 010. Run only against an isolated database.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_embedding vector(768) := array_prepend(1::real, array_fill(0::real, ARRAY[767]))::vector;
  v_ticket_id uuid;
  v_alerted_cluster_id uuid;
  v_stuck_cluster_id uuid;
  v_result text;
BEGIN
  IF to_regprocedure('ticket_cluster.record_review_action(uuid,text,text,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy record_review_action bypass still exists';
  END IF;

  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('pilot-gates-alerted-seed', 'Synthetic completed-cluster state guard test', 'pilot-gates-test', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    status, alerted_at
  ) VALUES (
    v_ticket_id, 'pilot-gates-test', v_embedding, v_embedding,
    'alerted', now()
  ) RETURNING id INTO v_alerted_cluster_id;

  SELECT record_cluster_verification(
    v_alerted_cluster_id, 'test-model', 'verified', 1, 'Synthetic result',
    ARRAY[v_ticket_id], '{"test":true}'::jsonb, 0.75
  ) INTO v_result;
  IF v_result <> 'ignored_wrong_state' THEN
    RAISE EXCEPTION 'completed-cluster verification was not rejected: %', v_result;
  END IF;
  IF (SELECT status FROM clusters WHERE id = v_alerted_cluster_id) <> 'alerted' THEN
    RAISE EXCEPTION 'completed cluster status was mutated';
  END IF;
  IF EXISTS (SELECT 1 FROM cluster_verifications WHERE cluster_id = v_alerted_cluster_id) THEN
    RAISE EXCEPTION 'ignored verification created an audit result';
  END IF;

  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('pilot-gates-stuck-seed', 'Synthetic stuck-verification incident test', 'pilot-gates-test', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    status, updated_at
  ) VALUES (
    v_ticket_id, 'pilot-gates-test', v_embedding, v_embedding,
    'verification_pending', now() - interval '30 minutes'
  ) RETURNING id INTO v_stuck_cluster_id;

  PERFORM * FROM refresh_operational_incidents(interval '15 minutes', interval '24 hours');
  IF NOT EXISTS (
    SELECT 1 FROM operational_incidents
    WHERE incident_key = 'verification:' || v_stuck_cluster_id::text
      AND kind = 'verification_stuck' AND severity = 'error' AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'stuck verification did not create an operational incident';
  END IF;
END;
$$;

SELECT 'PASS: legacy bypass removed, completed clusters protected, and stuck verification surfaced' AS result;
ROLLBACK;
