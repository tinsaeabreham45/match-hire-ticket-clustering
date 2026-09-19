-- Read-only structural checks for an isolated database after applying 001-006.
-- Run: psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_review_integrity.sql

BEGIN READ ONLY;

DO $$
BEGIN
  IF to_regclass('ticket_cluster.delivery_attempts') IS NULL THEN
    RAISE EXCEPTION 'delivery_attempts table is missing';
  END IF;
  IF to_regclass('ticket_cluster.authorized_approvers') IS NULL THEN
    RAISE EXCEPTION 'authorized_approvers table is missing';
  END IF;
  IF to_regclass('ticket_cluster.authorized_review_contexts') IS NULL THEN
    RAISE EXCEPTION 'authorized_review_contexts table is missing';
  END IF;
  IF to_regclass('ticket_cluster.review_action_attempts') IS NULL THEN
    RAISE EXCEPTION 'review_action_attempts table is missing';
  END IF;
  IF to_regprocedure('ticket_cluster.record_review_decision(uuid,uuid,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'record_review_decision function is missing';
  END IF;
  IF to_regprocedure('ticket_cluster.claim_delivery_attempt(uuid,integer)') IS NULL THEN
    RAISE EXCEPTION 'claim_delivery_attempt function is missing';
  END IF;
END;
$$;

SELECT 'PASS: review-integrity database objects exist' AS result;
ROLLBACK;
