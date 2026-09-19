-- Transactional integration test for migrations 004-006.
-- Run only against an isolated test database:
-- psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_outbox_state_machine.sql

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_embedding vector(768) := array_fill(0::real, ARRAY[768])::vector;
  v_ticket_id uuid;
  v_cluster_id uuid;
  v_draft_id uuid;
  v_attempt record;
  v_result text;
BEGIN
  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('hardening-state-machine-ticket', 'Synthetic delivery-state-machine ticket', 'test-embedding', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;

  INSERT INTO clusters (seed_ticket_id, embedding_model, seed_embedding, centroid_embedding, ticket_count, status)
  VALUES (v_ticket_id, 'test-embedding', v_embedding, v_embedding, 3, 'pending_review')
  RETURNING id INTO v_cluster_id;

  INSERT INTO cluster_report_drafts (
    cluster_id, model, summary, suspected_root_cause, impact, evidence, recommended_next_step, report, status
  ) VALUES (
    v_cluster_id, 'test-model', 'Synthetic summary', 'Synthetic cause', 'Synthetic impact', '[]'::jsonb,
    'Synthetic next step', '{}'::jsonb, 'pending_review'
  ) RETURNING id INTO v_draft_id;

  INSERT INTO authorized_approvers (slack_user_id) VALUES ('U_HARDENING_TEST');
  INSERT INTO authorized_review_contexts (slack_workspace_id, slack_channel_id) VALUES ('T_HARDENING_TEST', 'C_HARDENING_TEST');

  v_result := record_review_decision(v_cluster_id, v_draft_id, 'approve', 'U_DENIED', 'callback-denied', 'T_HARDENING_TEST', 'C_HARDENING_TEST');
  IF v_result <> 'denied_not_authorized' THEN RAISE EXCEPTION 'expected denied_not_authorized, got %', v_result; END IF;
  IF (SELECT count(*) FROM delivery_attempts WHERE report_draft_id = v_draft_id) <> 0 THEN RAISE EXCEPTION 'denied action queued delivery'; END IF;

  v_result := record_review_decision(v_cluster_id, v_draft_id, 'approve', 'U_HARDENING_TEST', 'callback-approved', 'T_HARDENING_TEST', 'C_HARDENING_TEST');
  IF v_result <> 'delivery_queued' THEN RAISE EXCEPTION 'expected delivery_queued, got %', v_result; END IF;
  IF (SELECT count(*) FROM delivery_attempts WHERE report_draft_id = v_draft_id) <> 3 THEN RAISE EXCEPTION 'expected exactly three outbox rows'; END IF;
  IF (SELECT status FROM cluster_report_drafts WHERE id = v_draft_id) <> 'delivery_pending' THEN RAISE EXCEPTION 'draft was not delivery_pending'; END IF;

  v_result := record_review_decision(v_cluster_id, v_draft_id, 'approve', 'U_HARDENING_TEST', 'callback-approved', 'T_HARDENING_TEST', 'C_HARDENING_TEST');
  IF v_result <> 'duplicate_callback' THEN RAISE EXCEPTION 'expected duplicate_callback, got %', v_result; END IF;
  IF (SELECT count(*) FROM delivery_attempts WHERE report_draft_id = v_draft_id) <> 3 THEN RAISE EXCEPTION 'duplicate callback created delivery rows'; END IF;

  SELECT * INTO v_attempt FROM claim_delivery_attempt(v_draft_id);
  IF v_attempt.target <> 'google_doc' THEN RAISE EXCEPTION 'expected google_doc first, got %', v_attempt.target; END IF;
  PERFORM complete_delivery_attempt(v_attempt.attempt_id, 'doc-test-id', 'https://example.invalid/doc-test-id');
  IF finalize_report_delivery(v_draft_id) THEN RAISE EXCEPTION 'delivery finalized before all stages'; END IF;

  SELECT * INTO v_attempt FROM claim_delivery_attempt(v_draft_id);
  IF v_attempt.target <> 'google_sheets' THEN RAISE EXCEPTION 'expected google_sheets second, got %', v_attempt.target; END IF;
  PERFORM complete_delivery_attempt(v_attempt.attempt_id);

  SELECT * INTO v_attempt FROM claim_delivery_attempt(v_draft_id);
  IF v_attempt.target <> 'eng_slack' THEN RAISE EXCEPTION 'expected eng_slack third, got %', v_attempt.target; END IF;
  PERFORM complete_delivery_attempt(v_attempt.attempt_id);
  IF NOT finalize_report_delivery(v_draft_id) THEN RAISE EXCEPTION 'delivery did not finalize after all stages'; END IF;
  IF (SELECT status FROM cluster_report_drafts WHERE id = v_draft_id) <> 'delivered' THEN RAISE EXCEPTION 'draft was not delivered'; END IF;
  IF (SELECT status FROM clusters WHERE id = v_cluster_id) <> 'alerted' THEN RAISE EXCEPTION 'cluster was not alerted'; END IF;
END;
$$;

SELECT 'PASS: denied, duplicate, ordered delivery, and finalization behavior verified' AS result;
ROLLBACK;
