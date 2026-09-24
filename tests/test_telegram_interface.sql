\set ON_ERROR_STOP on
BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_new record;
  v_preview record;
  v_callback record;
  v_job record;
  v_update record;
BEGIN
  SELECT * INTO v_update FROM register_telegram_update(900001,'message',101,501,30);
  IF NOT v_update.accepted THEN RAISE EXCEPTION 'first Telegram update was not accepted'; END IF;
  SELECT * INTO v_update FROM register_telegram_update(900001,'message',101,501,30);
  IF v_update.accepted OR v_update.disposition<>'duplicate' THEN RAISE EXCEPTION 'duplicate Telegram update was not suppressed'; END IF;

  SELECT * INTO v_new FROM handle_telegram_message(900001,101,'private',501,'Test User','/new');
  IF v_new.operation<>'reply' THEN RAISE EXCEPTION 'Telegram /new did not start a draft'; END IF;

  PERFORM register_telegram_update(900002,'message',101,501,30);
  SELECT * INTO v_preview FROM handle_telegram_message(
    900002,101,'private',501,'Test User',
    'Checkout payments fail with gateway timeout for multiple customers.'
  );
  IF v_preview.operation<>'preview' OR v_preview.confirm_token IS NULL THEN
    RAISE EXCEPTION 'Telegram ticket preview was not created';
  END IF;

  PERFORM register_telegram_update(900003,'callback_query',101,501,30);
  SELECT * INTO v_callback FROM process_telegram_callback(
    900003,'ticket-callback-1',v_preview.confirm_token,501,101,7001
  );
  IF v_callback.operation<>'ticket_queued' THEN RAISE EXCEPTION 'confirmed Telegram ticket was not durably queued'; END IF;

  SELECT * INTO v_job FROM claim_telegram_intake_job(5);
  IF v_job.job_id IS NULL OR v_job.source_event_id<>'telegram:101:900002' THEN
    RAISE EXCEPTION 'Telegram intake job was not claimable';
  END IF;
END;
$$;

DO $$
DECLARE
  v_embedding vector(768) := ('['||array_to_string(array_fill(0.001::real,ARRAY[768]),',')||']')::vector;
  v_job_id uuid;
  v_result record;
BEGIN
  SELECT id INTO v_job_id FROM telegram_intake_jobs WHERE source_event_id='telegram:101:900002';
  SELECT * INTO v_result FROM complete_telegram_intake_job(v_job_id,v_embedding);
  IF v_result.ticket_id IS NULL OR v_result.disposition NOT IN ('clustered','new_episode') THEN
    RAISE EXCEPTION 'Telegram intake job did not create a clustered ticket';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM tickets WHERE id=v_result.ticket_id AND source='telegram'
      AND metadata->>'telegram_user_id'='501'
  ) THEN RAISE EXCEPTION 'Telegram source metadata was not persisted'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM telegram_ticket_sessions WHERE chat_id=101 AND telegram_user_id=501
      AND state='open' AND ticket_id=v_result.ticket_id
  ) THEN RAISE EXCEPTION 'Telegram session was not opened after clustering'; END IF;
END;
$$;

DO $$
DECLARE
  v_embedding vector(768) := ('['||array_to_string(array_fill(0.002::real,ARRAY[768]),',')||']')::vector;
  v_ticket_id uuid;
  v_cluster_id uuid;
  v_draft_id uuid;
  v_surface record;
  v_denied record;
  v_approved record;
BEGIN
  INSERT INTO telegram_connections(role,chat_id,chat_type,title,connected_by_user_id)
  VALUES
    ('review',-100100,'supergroup','Review',501),
    ('engineering',-100200,'supergroup','Engineering',501);
  INSERT INTO authorized_telegram_approvers(telegram_user_id,display_name)
  VALUES (501,'Test User');

  INSERT INTO tickets(source_event_id,source,raw_text,embedding_model,embedding,disposition)
  VALUES ('telegram-review-seed','telegram','Repeated checkout gateway timeout','test-model',v_embedding,'clustered')
  RETURNING id INTO v_ticket_id;
  INSERT INTO clusters(
    seed_ticket_id,embedding_model,seed_embedding,centroid_embedding,ticket_count,status
  ) VALUES (v_ticket_id,'test-model',v_embedding,v_embedding,3,'pending_review')
  RETURNING id INTO v_cluster_id;
  INSERT INTO cluster_tickets(cluster_id,ticket_id,assignment_similarity)
  VALUES (v_cluster_id,v_ticket_id,1.0);
  INSERT INTO cluster_report_drafts(
    cluster_id,model,summary,suspected_root_cause,impact,evidence,
    recommended_next_step,report,delivery_channel
  ) VALUES (
    v_cluster_id,'test-model','Checkout failures','Gateway unavailable','Payments blocked',
    '[]'::jsonb,'Check gateway health','{}'::jsonb,'telegram'
  ) RETURNING id INTO v_draft_id;

  SELECT * INTO v_surface FROM create_telegram_review_surface('report',v_draft_id);
  PERFORM mark_telegram_review_surface_sent(v_surface.surface_id,8001);

  SELECT * INTO v_denied FROM process_telegram_callback(
    900010,'review-denied-1',v_surface.approve_token,999,-100100,8001
  );
  IF v_denied.outcome<>'denied_not_authorized' THEN RAISE EXCEPTION 'unauthorized Telegram reviewer was not denied'; END IF;

  SELECT * INTO v_approved FROM process_telegram_callback(
    900011,'review-approved-1',v_surface.approve_token,501,-100100,8001
  );
  IF v_approved.outcome<>'delivery_queued' THEN RAISE EXCEPTION 'authorized Telegram approval did not queue delivery'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM delivery_attempts
    WHERE report_draft_id=v_draft_id AND target='eng_telegram' AND destination_ref='-100200'
  ) THEN RAISE EXCEPTION 'Telegram engineering delivery target was not snapshotted'; END IF;
  IF EXISTS (
    SELECT 1 FROM delivery_attempts WHERE report_draft_id=v_draft_id AND target='eng_slack'
  ) THEN RAISE EXCEPTION 'Telegram report incorrectly queued a Slack engineering target'; END IF;
  IF (SELECT status FROM telegram_review_surfaces WHERE id=v_surface.surface_id)<>'decided' THEN
    RAISE EXCEPTION 'Telegram review surface remained actionable';
  END IF;
END;
$$;

ROLLBACK;
\echo 'PASS: Telegram SQL intake, idempotency, authorization, review, and routing checks.'

