-- Baseline privacy controls for the single-tenant system.
-- Apply after 001-007. This migration redacts common PII before persistence.

SET search_path TO ticket_cluster, public;

CREATE OR REPLACE FUNCTION redact_ticket_text(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT regexp_replace(
    regexp_replace(
      regexp_replace(coalesce(p_text, ''),
        '\\m[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\M', '[REDACTED_EMAIL]', 'gi'),
      '\\m[0-9][0-9 -]{11,17}[0-9]\\M', '[REDACTED_CARD]', 'g'),
    '(^|[^[:alnum:]])[+]?[0-9][0-9(). -]{7,}[0-9]([^[:alnum:]]|$)', E'\\1[REDACTED_PHONE]\\2', 'g');
$$;

ALTER TABLE tickets
  ADD COLUMN IF NOT EXISTS pii_redacted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS content_redacted_at timestamptz;

CREATE OR REPLACE FUNCTION redact_ticket_before_write()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_redacted text;
BEGIN
  v_redacted := redact_ticket_text(NEW.raw_text);
  IF v_redacted IS DISTINCT FROM NEW.raw_text THEN
    NEW.raw_text := v_redacted;
    NEW.pii_redacted := true;
    NEW.content_redacted_at := coalesce(NEW.content_redacted_at, now());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tickets_redact_before_write ON tickets;
CREATE TRIGGER tickets_redact_before_write
BEFORE INSERT OR UPDATE OF raw_text ON tickets
FOR EACH ROW EXECUTE FUNCTION redact_ticket_before_write();

-- Backfill existing ticket content. Review this in staging first; it is
-- intentionally irreversible because raw PII should not be retained.
UPDATE tickets
SET raw_text = redact_ticket_text(raw_text),
    pii_redacted = true,
    content_redacted_at = coalesce(content_redacted_at, now())
WHERE raw_text IS DISTINCT FROM redact_ticket_text(raw_text);

CREATE TABLE IF NOT EXISTS data_retention_policies (
  scope text PRIMARY KEY CHECK (scope IN ('tickets')),
  retain_days integer NOT NULL CHECK (retain_days BETWEEN 1 AND 3650),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO data_retention_policies (scope, retain_days)
VALUES ('tickets', 30)
ON CONFLICT (scope) DO NOTHING;

CREATE OR REPLACE FUNCTION redact_expired_ticket_content(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_count integer;
BEGIN
  WITH policy AS (
    SELECT retain_days FROM data_retention_policies WHERE scope = 'tickets'
  ), due AS (
    SELECT t.id
    FROM tickets t CROSS JOIN policy p
    WHERE t.received_at < now() - make_interval(days => p.retain_days)
      AND t.raw_text <> '[REDACTED: retention period elapsed]'
    ORDER BY t.received_at
    LIMIT greatest(1, least(p_limit, 5000))
  )
  UPDATE tickets t
  SET raw_text = '[REDACTED: retention period elapsed]',
      embedding = NULL,
      pii_redacted = true,
      content_redacted_at = now(),
      metadata = t.metadata || jsonb_build_object('content_retained', false)
  FROM due
  WHERE t.id = due.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
