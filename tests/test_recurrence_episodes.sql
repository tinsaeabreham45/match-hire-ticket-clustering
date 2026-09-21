-- Transactional checks for migration 009. Run only against an isolated database.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_old_embedding vector(768) := array_prepend(1::real, array_fill(0::real, ARRAY[767]))::vector;
  v_recent_embedding vector(768) := array_cat(ARRAY[0::real, 1::real], array_fill(0::real, ARRAY[766]))::vector;
  v_ticket_id uuid;
  v_old_cluster_id uuid;
  v_recent_cluster_id uuid;
  v_new_episode_id uuid;
  v_result record;
BEGIN
  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('recurrence-old-seed', 'Old alerted incident seed ticket', 'recurrence-test-model', v_old_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;

  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    ticket_count, status, alerted_at, recurrence_cooldown
  ) VALUES (
    v_ticket_id, 'recurrence-test-model', v_old_embedding, v_old_embedding,
    3, 'alerted', now() - interval '2 days', interval '24 hours'
  ) RETURNING id INTO v_old_cluster_id;
  INSERT INTO cluster_tickets (cluster_id, ticket_id, assignment_similarity)
  VALUES (v_old_cluster_id, v_ticket_id, 1);

  SELECT * INTO v_result FROM ingest_ticket(
    'recurrence-episode-2-a', 'Recurring incident episode ticket A', now(),
    v_old_embedding, 'recurrence-test-model', 0.84, 3, 3, 'recurrence-test'
  );
  IF v_result.disposition <> 'new_episode' THEN RAISE EXCEPTION 'expected new_episode, got %', v_result.disposition; END IF;
  IF v_result.cluster_id = v_old_cluster_id THEN RAISE EXCEPTION 'recurrence reused the immutable alerted cluster'; END IF;
  v_new_episode_id := v_result.cluster_id;
  IF (SELECT episode_number FROM clusters WHERE id=v_new_episode_id) <> 2 THEN RAISE EXCEPTION 'new recurrence was not episode 2'; END IF;
  IF (SELECT previous_episode_id FROM clusters WHERE id=v_new_episode_id) <> v_old_cluster_id THEN RAISE EXCEPTION 'new episode did not link to previous episode'; END IF;
  IF (SELECT recurrence_group_id FROM clusters WHERE id=v_new_episode_id) <> (SELECT recurrence_group_id FROM clusters WHERE id=v_old_cluster_id) THEN RAISE EXCEPTION 'recurrence group was not preserved'; END IF;

  SELECT * INTO v_result FROM ingest_ticket(
    'recurrence-episode-2-b', 'Recurring incident episode ticket B', now(),
    v_old_embedding, 'recurrence-test-model', 0.84, 3, 3, 'recurrence-test'
  );
  IF v_result.cluster_id <> v_new_episode_id OR v_result.review_required THEN RAISE EXCEPTION 'second ticket did not remain in episode 2'; END IF;

  SELECT * INTO v_result FROM ingest_ticket(
    'recurrence-episode-2-c', 'Recurring incident episode ticket C', now(),
    v_old_embedding, 'recurrence-test-model', 0.84, 3, 3, 'recurrence-test'
  );
  IF v_result.cluster_id <> v_new_episode_id OR NOT v_result.review_required THEN RAISE EXCEPTION 'episode 2 did not claim one review at threshold'; END IF;
  IF (SELECT ticket_count FROM clusters WHERE id=v_old_cluster_id) <> 3 THEN RAISE EXCEPTION 'episode 1 ticket count was mutated'; END IF;
  IF (SELECT status FROM clusters WHERE id=v_old_cluster_id) <> 'alerted' THEN RAISE EXCEPTION 'episode 1 status was mutated'; END IF;

  SELECT * INTO v_result FROM ingest_ticket(
    'recurrence-episode-2-c', 'Recurring incident episode ticket C', now(),
    v_old_embedding, 'recurrence-test-model', 0.84, 3, 3, 'recurrence-test'
  );
  IF v_result.disposition <> 'duplicate' OR v_result.review_required THEN RAISE EXCEPTION 'duplicate recurrence ticket was not idempotent'; END IF;

  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('recurrence-recent-seed', 'Recently alerted incident seed', 'recurrence-test-model', v_recent_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (
    seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
    ticket_count, status, alerted_at, recurrence_cooldown
  ) VALUES (
    v_ticket_id, 'recurrence-test-model', v_recent_embedding, v_recent_embedding,
    1, 'alerted', now(), interval '24 hours'
  ) RETURNING id INTO v_recent_cluster_id;
  INSERT INTO cluster_tickets (cluster_id, ticket_id, assignment_similarity)
  VALUES (v_recent_cluster_id, v_ticket_id, 1);

  SELECT * INTO v_result FROM ingest_ticket(
    'recurrence-within-cooldown', 'Late-arriving ticket inside the same incident window', now(),
    v_recent_embedding, 'recurrence-test-model', 0.84, 3, 3, 'recurrence-test'
  );
  IF v_result.cluster_id <> v_recent_cluster_id OR v_result.disposition <> 'clustered' THEN RAISE EXCEPTION 'cooldown ticket opened a premature episode'; END IF;
  IF (SELECT max(episode_number) FROM clusters WHERE recurrence_group_id=(SELECT recurrence_group_id FROM clusters WHERE id=v_recent_cluster_id)) <> 1 THEN RAISE EXCEPTION 'cooldown created an unexpected later episode'; END IF;
END;
$$;

SELECT 'PASS: recurrence cooldown, linked episode creation, threshold crossing, and idempotency verified' AS result;
ROLLBACK;
