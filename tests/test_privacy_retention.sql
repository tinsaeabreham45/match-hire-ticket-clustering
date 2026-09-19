-- Transactional checks for migration 008. Run only against an isolated DB.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_ticket_id uuid;
  v_text text;
  v_changed integer;
BEGIN
  INSERT INTO tickets (source_event_id, raw_text, received_at, disposition)
  VALUES (
    'privacy-test-pii',
    'Contact jane.doe@example.com or +1 415 555 0199. Card 4111 1111 1111 1111 failed.',
    now() - interval '90 days',
    'received'
  ) RETURNING id, raw_text INTO v_ticket_id, v_text;

  IF v_text ~* 'jane\\.doe@example\\.com|4111 1111|415 555 0199' THEN
    RAISE EXCEPTION 'raw PII was stored: %', v_text;
  END IF;
  IF v_text !~ 'REDACTED_EMAIL|REDACTED_CARD|REDACTED_PHONE' THEN
    RAISE EXCEPTION 'expected redaction markers, got %', v_text;
  END IF;

  SELECT redact_expired_ticket_content(10) INTO v_changed;
  IF v_changed < 1 THEN RAISE EXCEPTION 'expected retention redaction to change a ticket'; END IF;
  IF (SELECT raw_text FROM tickets WHERE id = v_ticket_id) <> '[REDACTED: retention period elapsed]' THEN
    RAISE EXCEPTION 'retention did not remove stored ticket content';
  END IF;
END;
$$;

SELECT 'PASS: write-time PII redaction and retention redaction verified' AS result;
ROLLBACK;
