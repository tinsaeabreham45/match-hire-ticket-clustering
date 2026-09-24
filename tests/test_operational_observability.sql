-- Transactional checks for migrations 007 and 013. Run only against an isolated DB.

BEGIN;
SET search_path TO ticket_cluster, public;

DO $$
DECLARE
  v_key text;
  v_count integer;
BEGIN
  PERFORM * FROM refresh_operational_incidents();

  PERFORM record_workflow_failure('workflow-test', 'execution-test-007', 'Synthetic node', 'Synthetic provider timeout');
  SELECT incident_key INTO v_key
  FROM list_operational_incidents_to_notify(interval '1 hour')
  WHERE incident_key = 'workflow:execution-test-007';
  IF v_key IS NULL THEN RAISE EXCEPTION 'workflow failure was not surfaced as a notifyable incident'; END IF;

  SELECT mark_operational_incidents_notified(ARRAY[v_key]) INTO v_count;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected one notified incident, got %', v_count; END IF;
  IF EXISTS (SELECT 1 FROM list_operational_incidents_to_notify(interval '0 seconds') WHERE incident_key = v_key) THEN
    RAISE EXCEPTION 'one-off workflow failure repeated after notification';
  END IF;

  PERFORM record_workflow_failure('workflow-test', 'execution-test-007', 'Synthetic node', 'Synthetic provider timeout');
  IF EXISTS (SELECT 1 FROM list_operational_incidents_to_notify(interval '0 seconds') WHERE incident_key = v_key) THEN
    RAISE EXCEPTION 'duplicate capture reset one-off workflow failure notification state';
  END IF;

  INSERT INTO operational_incidents (incident_key, kind, severity, message)
  VALUES ('test:warning-once', 'review_overdue', 'warning', 'Synthetic warning');
  PERFORM mark_operational_incidents_notified(ARRAY['test:warning-once']);
  IF EXISTS (
    SELECT 1 FROM list_operational_incidents_to_notify(interval '0 seconds')
    WHERE incident_key = 'test:warning-once'
  ) THEN
    RAISE EXCEPTION 'warning incident was repeated after notification';
  END IF;

  INSERT INTO operational_incidents (incident_key, kind, severity, message)
  VALUES ('test:persistent-error', 'verification_stuck', 'error', 'Synthetic persistent error');
  PERFORM mark_operational_incidents_notified(ARRAY['test:persistent-error']);
  UPDATE operational_incidents
  SET notified_at = now() - interval '1 minute'
  WHERE incident_key = 'test:persistent-error';
  IF NOT EXISTS (
    SELECT 1 FROM list_operational_incidents_to_notify(interval '0 seconds')
    WHERE incident_key = 'test:persistent-error'
  ) THEN
    RAISE EXCEPTION 'persistent condition-based error did not remain repeatable';
  END IF;

  PERFORM acknowledge_operational_incident(v_key, 'operator-test', 'Investigating synthetic failure');
  IF (SELECT status FROM operational_incidents WHERE incident_key = v_key) <> 'acknowledged' THEN
    RAISE EXCEPTION 'incident was not acknowledged';
  END IF;

  PERFORM resolve_operational_incident(v_key, 'operator-test', 'Synthetic recovery verified');
  IF (SELECT status FROM operational_incidents WHERE incident_key = v_key) <> 'resolved' THEN
    RAISE EXCEPTION 'incident was not resolved';
  END IF;
  IF EXISTS (SELECT 1 FROM list_operational_incidents_to_notify(interval '0 seconds') WHERE incident_key = v_key) THEN
    RAISE EXCEPTION 'resolved workflow incident remained notifyable';
  END IF;

  PERFORM record_workflow_failure('workflow-test', 'execution-test-007', 'Synthetic node', 'Duplicate capture after recovery');
  IF (SELECT status FROM operational_incidents WHERE incident_key = v_key) <> 'resolved' THEN
    RAISE EXCEPTION 'duplicate capture reopened a resolved execution incident';
  END IF;
END;
$$;

SELECT 'PASS: workflow failures notify once, persistent errors repeat, and resolution is durable' AS result;
ROLLBACK;
