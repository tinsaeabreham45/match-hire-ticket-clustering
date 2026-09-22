-- Transactional checks for migration 012. Run only against an isolated database.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_embedding vector(768) := array_prepend(1::real, array_fill(0::real, ARRAY[767]))::vector;
  v_ticket_id uuid;
  v_cluster_id uuid;
  v_investigation_id uuid;
  v_repeat_investigation_id uuid;
  v_should_notify boolean;
  v_outcome text;
  v_index integer;
  v_action text;
  v_expected_status text;
BEGIN
  INSERT INTO authorized_approvers (slack_user_id) VALUES ('U_INVESTIGATION_TEST')
  ON CONFLICT (slack_user_id) DO UPDATE SET active = true;
  INSERT INTO authorized_review_contexts (slack_workspace_id, slack_channel_id)
  VALUES ('T_INVESTIGATION_TEST', 'C_INVESTIGATION_TEST')
  ON CONFLICT (slack_workspace_id, slack_channel_id) DO UPDATE SET active = true;

  INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
  VALUES ('investigation-card-retry-seed', 'Synthetic low-confidence investigation retry test', 'investigation-card-test', v_embedding, 'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters (seed_ticket_id, embedding_model, seed_embedding, centroid_embedding, status)
  VALUES (v_ticket_id, 'investigation-card-test', v_embedding, v_embedding, 'needs_review')
  RETURNING id INTO v_cluster_id;
  INSERT INTO cluster_verifications (
    cluster_id, model, verdict, confidence, root_cause, evidence_ticket_ids, response
  ) VALUES (
    v_cluster_id, 'test-model', 'needs_review', 0.3,
    'Insufficient evidence', ARRAY[v_ticket_id], '{"test":true}'::jsonb
  );

  SELECT investigation_id, should_notify
  INTO v_investigation_id, v_should_notify
  FROM create_cluster_investigation(v_cluster_id);
  IF NOT v_should_notify THEN RAISE EXCEPTION 'new investigation did not request a Slack card'; END IF;

  SELECT investigation_id, should_notify
  INTO v_repeat_investigation_id, v_should_notify
  FROM create_cluster_investigation(v_cluster_id);
  IF v_repeat_investigation_id <> v_investigation_id OR NOT v_should_notify THEN
    RAISE EXCEPTION 'unnotified investigation was not safely reused';
  END IF;

  PERFORM mark_investigation_notified(v_investigation_id, 'C_INVESTIGATION_TEST', '123.456');
  SELECT should_notify INTO v_should_notify FROM create_cluster_investigation(v_cluster_id);
  IF v_should_notify THEN RAISE EXCEPTION 'notified investigation requested a duplicate card'; END IF;

  INSERT INTO operational_incidents (incident_key, kind, severity, reference_id, message)
  VALUES ('verification:' || v_cluster_id::text, 'verification_attention', 'warning', v_cluster_id::text, 'Synthetic warning');

  SELECT record_investigation_decision(
    v_cluster_id, v_investigation_id, 'retry', 'U_NOT_AUTHORIZED',
    'investigation-callback-denied', 'T_INVESTIGATION_TEST', 'C_INVESTIGATION_TEST'
  ) INTO v_outcome;
  IF v_outcome <> 'denied_not_authorized' OR (SELECT status FROM clusters WHERE id=v_cluster_id) <> 'needs_review' THEN
    RAISE EXCEPTION 'unauthorized retry changed investigation state';
  END IF;

  SELECT record_investigation_decision(
    v_cluster_id, v_investigation_id, 'retry', 'U_INVESTIGATION_TEST',
    'investigation-callback-retry', 'T_INVESTIGATION_TEST', 'C_INVESTIGATION_TEST'
  ) INTO v_outcome;
  IF v_outcome <> 'retry_queued'
     OR (SELECT status FROM clusters WHERE id=v_cluster_id) <> 'verification_pending'
     OR (SELECT status FROM cluster_investigations WHERE id=v_investigation_id) <> 'retry_requested'
     OR (SELECT status FROM operational_incidents WHERE incident_key='verification:' || v_cluster_id::text) <> 'resolved' THEN
    RAISE EXCEPTION 'authorized retry did not transition atomically';
  END IF;
  SELECT record_investigation_decision(
    v_cluster_id, v_investigation_id, 'retry', 'U_INVESTIGATION_TEST',
    'investigation-callback-retry', 'T_INVESTIGATION_TEST', 'C_INVESTIGATION_TEST'
  ) INTO v_outcome;
  IF v_outcome <> 'duplicate_callback' THEN RAISE EXCEPTION 'retry callback was not idempotent'; END IF;

  FOR v_index IN 1..2 LOOP
    v_action := CASE v_index WHEN 1 THEN 'dismiss' ELSE 'split' END;
    v_expected_status := CASE v_index WHEN 1 THEN 'rejected' ELSE 'split' END;
    INSERT INTO tickets (source_event_id, raw_text, embedding_model, embedding, disposition)
    VALUES ('investigation-card-' || v_action || '-seed', 'Synthetic investigation action test ' || v_action, 'investigation-card-test', v_embedding, 'clustered')
    RETURNING id INTO v_ticket_id;
    INSERT INTO clusters (seed_ticket_id, embedding_model, seed_embedding, centroid_embedding, status)
    VALUES (v_ticket_id, 'investigation-card-test', v_embedding, v_embedding, 'needs_review')
    RETURNING id INTO v_cluster_id;
    INSERT INTO cluster_verifications (
      cluster_id, model, verdict, confidence, root_cause, evidence_ticket_ids, response
    ) VALUES (
      v_cluster_id, 'test-model', 'needs_review', 0.2,
      'Insufficient evidence', ARRAY[v_ticket_id], '{"test":true}'::jsonb
    );
    SELECT investigation_id INTO v_investigation_id FROM create_cluster_investigation(v_cluster_id);
    SELECT record_investigation_decision(
      v_cluster_id, v_investigation_id, v_action, 'U_INVESTIGATION_TEST',
      'investigation-callback-' || v_action, 'T_INVESTIGATION_TEST', 'C_INVESTIGATION_TEST'
    ) INTO v_outcome;
    IF v_outcome <> (CASE v_action WHEN 'dismiss' THEN 'dismissed' ELSE 'split' END)
       OR (SELECT status FROM clusters WHERE id=v_cluster_id) <> v_expected_status THEN
      RAISE EXCEPTION '% action did not close the investigation safely', v_action;
    END IF;
  END LOOP;
END;
$$;

SELECT 'PASS: investigation creation, notification, authorization, retry, dismiss, split, and idempotency verified' AS result;
ROLLBACK;
