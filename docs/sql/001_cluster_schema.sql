-- Support-ticket root-cause clustering state.
-- Apply with a role allowed to create extensions, then use a least-privilege
-- n8n database role for normal workflow operations. This migration never
-- contains credentials.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS ticket_cluster;
SET search_path TO ticket_cluster, public;

CREATE TABLE IF NOT EXISTS tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_event_id text NOT NULL UNIQUE,
  source text NOT NULL DEFAULT 'slack',
  raw_text text NOT NULL DEFAULT '',
  received_at timestamptz NOT NULL DEFAULT now(),
  embedding_model text,
  embedding vector(768),
  disposition text NOT NULL DEFAULT 'received'
    CHECK (disposition IN ('received', 'clustered', 'rejected_invalid', 'embedding_failed', 'duplicate')),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS clusters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seed_ticket_id uuid NOT NULL REFERENCES tickets(id),
  embedding_model text NOT NULL,
  seed_embedding vector(768) NOT NULL,
  centroid_embedding vector(768) NOT NULL,
  ticket_count integer NOT NULL DEFAULT 1 CHECK (ticket_count > 0),
  assignment_threshold real NOT NULL DEFAULT 0.84 CHECK (assignment_threshold > -1 AND assignment_threshold < 1),
  verification_threshold integer NOT NULL DEFAULT 3 CHECK (verification_threshold > 0),
  alert_threshold integer NOT NULL DEFAULT 3 CHECK (alert_threshold > 0),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'verification_pending', 'pending_review', 'needs_review', 'approved', 'alerted', 'rejected', 'split')),
  alerted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cluster_tickets (
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  ticket_id uuid NOT NULL UNIQUE REFERENCES tickets(id) ON DELETE CASCADE,
  assignment_similarity real NOT NULL CHECK (assignment_similarity >= -1 AND assignment_similarity <= 1),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cluster_id, ticket_id)
);

CREATE TABLE IF NOT EXISTS cluster_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  model text NOT NULL,
  verdict text NOT NULL CHECK (verdict IN ('verified', 'rejected', 'needs_review')),
  confidence real NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  root_cause text,
  evidence_ticket_ids uuid[] NOT NULL DEFAULT '{}',
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cluster_report_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  verification_id uuid REFERENCES cluster_verifications(id) ON DELETE SET NULL,
  model text NOT NULL,
  summary text NOT NULL,
  suspected_root_cause text NOT NULL,
  impact text NOT NULL,
  evidence jsonb NOT NULL,
  recommended_next_step text NOT NULL,
  report jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'approved', 'rejected', 'split', 'delivery_pending', 'delivered')),
  google_doc_id text,
  google_doc_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cluster_review_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id uuid NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('approve', 'reject', 'split', 'reopen')),
  actor_id text NOT NULL,
  callback_id text NOT NULL UNIQUE,
  notes text,
  acted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS workflow_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_event_id text,
  workflow_version text NOT NULL,
  stage text NOT NULL,
  outcome text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tickets_received_at_idx ON tickets (received_at DESC);
CREATE INDEX IF NOT EXISTS clusters_status_idx ON clusters (status, updated_at DESC);
CREATE INDEX IF NOT EXISTS cluster_tickets_cluster_idx ON cluster_tickets (cluster_id);
CREATE INDEX IF NOT EXISTS cluster_report_drafts_cluster_idx ON cluster_report_drafts (cluster_id, created_at DESC);
CREATE INDEX IF NOT EXISTS clusters_seed_embedding_hnsw
  ON clusters USING hnsw (seed_embedding vector_cosine_ops);

CREATE OR REPLACE FUNCTION ingest_ticket(
  p_source_event_id text,
  p_text text,
  p_received_at timestamptz,
  p_embedding vector(768),
  p_embedding_model text,
  p_assignment_threshold real DEFAULT 0.84,
  p_verification_threshold integer DEFAULT 3,
  p_alert_threshold integer DEFAULT 3,
  p_workflow_version text DEFAULT 'v0'
)
RETURNS TABLE (
  ticket_id uuid,
  cluster_id uuid,
  disposition text,
  similarity real,
  review_required boolean
)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_ticket_id uuid;
  v_cluster_id uuid;
  v_cluster clusters%ROWTYPE;
  v_similarity real;
  v_ticket_count integer;
  v_matched boolean;
BEGIN
  IF coalesce(btrim(p_source_event_id), '') = '' THEN
    RAISE EXCEPTION 'source_event_id is required';
  END IF;

  IF char_length(btrim(coalesce(p_text, ''))) < 10 THEN
    INSERT INTO tickets (source_event_id, raw_text, received_at, disposition)
    VALUES (p_source_event_id, coalesce(p_text, ''), coalesce(p_received_at, now()), 'rejected_invalid')
    ON CONFLICT (source_event_id) DO NOTHING
    RETURNING id INTO v_ticket_id;

    IF v_ticket_id IS NULL THEN
      SELECT id INTO v_ticket_id FROM tickets WHERE source_event_id = p_source_event_id;
      RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'duplicate', NULL::real, false;
    ELSE
      INSERT INTO workflow_runs (source_event_id, workflow_version, stage, outcome)
      VALUES (p_source_event_id, p_workflow_version, 'validation', 'rejected_invalid');
      RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'rejected_invalid', NULL::real, false;
    END IF;
    RETURN;
  END IF;

  IF p_embedding IS NULL OR p_embedding_model IS NULL THEN
    RAISE EXCEPTION 'embedding and embedding_model are required for a valid ticket';
  END IF;

  INSERT INTO tickets (source_event_id, raw_text, received_at, embedding_model, embedding)
  VALUES (p_source_event_id, p_text, coalesce(p_received_at, now()), p_embedding_model, p_embedding)
  ON CONFLICT (source_event_id) DO NOTHING
  RETURNING id INTO v_ticket_id;

  IF v_ticket_id IS NULL THEN
    SELECT t.id, ct.cluster_id, ct.assignment_similarity
    INTO v_ticket_id, v_cluster_id, v_similarity
    FROM tickets t LEFT JOIN cluster_tickets ct ON ct.ticket_id = t.id
    WHERE t.source_event_id = p_source_event_id;
    RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'duplicate', v_similarity, false;
    RETURN;
  END IF;

  SELECT c.*
  INTO v_cluster
  FROM clusters c
  WHERE c.embedding_model = p_embedding_model
    AND c.status IN ('active', 'verification_pending', 'pending_review', 'needs_review', 'approved', 'alerted')
  ORDER BY c.seed_embedding <=> p_embedding
  LIMIT 1;

  v_matched := FOUND;

  IF v_matched THEN
    v_similarity := (1 - (v_cluster.seed_embedding <=> p_embedding))::real;
  END IF;

  IF v_matched AND v_similarity >= v_cluster.assignment_threshold THEN
    v_cluster_id := v_cluster.id;
  ELSE
    INSERT INTO clusters (
      seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
      assignment_threshold, verification_threshold, alert_threshold
    ) VALUES (
      v_ticket_id, p_embedding_model, p_embedding, p_embedding,
      p_assignment_threshold, p_verification_threshold, p_alert_threshold
    ) RETURNING id INTO v_cluster_id;
    v_similarity := 1.0;
  END IF;

  INSERT INTO cluster_tickets (cluster_id, ticket_id, assignment_similarity)
  VALUES (v_cluster_id, v_ticket_id, v_similarity);

  UPDATE tickets SET disposition = 'clustered' WHERE id = v_ticket_id;
  UPDATE clusters c
  SET ticket_count = counts.ticket_count,
      centroid_embedding = counts.centroid_embedding,
      updated_at = now()
  FROM (
    SELECT ct.cluster_id, count(*)::integer AS ticket_count, avg(t.embedding) AS centroid_embedding
    FROM cluster_tickets ct
    JOIN tickets t ON t.id = ct.ticket_id
    WHERE ct.cluster_id = v_cluster_id
    GROUP BY ct.cluster_id
  ) counts
  WHERE c.id = counts.cluster_id;

  SELECT * INTO v_cluster FROM clusters WHERE id = v_cluster_id;
  v_ticket_count := v_cluster.ticket_count;
  IF v_ticket_count >= v_cluster.verification_threshold
     AND v_cluster.status = 'active' THEN
    UPDATE clusters SET status = 'verification_pending', updated_at = now() WHERE id = v_cluster_id;
    INSERT INTO workflow_runs (source_event_id, workflow_version, stage, outcome)
    VALUES (p_source_event_id, p_workflow_version, 'assignment', 'verification_required');
    RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'clustered', v_similarity, true;
  ELSE
    RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'clustered', v_similarity, false;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION record_cluster_verification(
  p_cluster_id uuid,
  p_model text,
  p_verdict text,
  p_confidence real,
  p_root_cause text,
  p_evidence_ticket_ids uuid[],
  p_response jsonb,
  p_confidence_threshold real DEFAULT 0.75
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_status text;
BEGIN
  IF p_verdict NOT IN ('verified', 'rejected', 'needs_review') OR p_response IS NULL THEN
    RAISE EXCEPTION 'invalid structured verification result';
  END IF;
  INSERT INTO cluster_verifications (cluster_id, model, verdict, confidence, root_cause, evidence_ticket_ids, response)
  VALUES (p_cluster_id, p_model, p_verdict, p_confidence, p_root_cause, p_evidence_ticket_ids, p_response);

  v_status := CASE
    WHEN p_verdict = 'verified' AND p_confidence >= p_confidence_threshold THEN 'pending_review'
    ELSE 'needs_review'
  END;
  UPDATE clusters SET status = v_status, updated_at = now() WHERE id = p_cluster_id;
  RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION record_review_action(
  p_cluster_id uuid,
  p_action text,
  p_actor_id text,
  p_callback_id text,
  p_notes text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_current_status text;
BEGIN
  INSERT INTO cluster_review_actions (cluster_id, action, actor_id, callback_id, notes)
  VALUES (p_cluster_id, p_action, p_actor_id, p_callback_id, p_notes)
  ON CONFLICT (callback_id) DO NOTHING;
  IF NOT FOUND THEN RETURN 'duplicate_callback'; END IF;

  SELECT status INTO v_current_status FROM clusters WHERE id = p_cluster_id FOR UPDATE;
  IF v_current_status IS NULL THEN RAISE EXCEPTION 'unknown cluster'; END IF;
  IF p_action = 'reopen' THEN
    UPDATE clusters SET status = 'active', alerted_at = NULL, updated_at = now() WHERE id = p_cluster_id;
    RETURN 'active';
  END IF;
  IF v_current_status <> 'pending_review' THEN RETURN 'ignored_not_pending'; END IF;

  UPDATE clusters
  SET status = CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' WHEN 'split' THEN 'split' END,
      updated_at = now()
  WHERE id = p_cluster_id;
  RETURN CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' WHEN 'split' THEN 'split' END;
END;
$$;
