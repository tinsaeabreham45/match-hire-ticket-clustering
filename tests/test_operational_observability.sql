-- Transactional checks for migration 007. Run only against an isolated DB.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_key text;
  v_count integer;
BEGIN
  PERFORM record_workflow_failure('workflow-test', 'execution-test-007', 'Synthetic node', 'Synthetic provider timeout');
  SELECT incident_key INTO v_key
  FROM list_operational_incidents_to_notify(interval '1 hour')
  WHERE incident_key = 'workflow:execution-test-007';
  IF v_key IS NULL THEN RAISE EXCEPTION 'workflow failure was not surfaced as a notifyable incident'; END IF;

  SELECT mark_operational_incidents_notified(ARRAY[v_key]) INTO v_count;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected one notified incident, got %', v_count; END IF;
  IF EXISTS (SELECT 1 FROM list_operational_incidents_to_notify(interval '1 hour') WHERE incident_key = v_key) THEN
    RAISE EXCEPTION 'notified incident was not rate limited';
  END IF;

  PERFORM acknowledge_operational_incident(v_key, 'operator-test', 'Synthetic acknowledgement');
  IF (SELECT status FROM operational_incidents WHERE incident_key = v_key) <> 'acknowledged' THEN
    RAISE EXCEPTION 'incident was not acknowledged';
  END IF;
END;
$$;

SELECT 'PASS: operational failure capture, notification rate limit, and acknowledgement verified' AS result;
ROLLBACK;
