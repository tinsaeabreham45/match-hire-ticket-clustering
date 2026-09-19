-- Serialize cluster assignment per embedding model.
-- Apply after 001-003; compatible with 004-005.

SET search_path TO ticket_cluster, public;

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
RETURNS TABLE (ticket_id uuid, cluster_id uuid, disposition text, similarity real, review_required boolean)
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE
  v_ticket_id uuid;
  v_cluster_id uuid;
  v_cluster clusters%ROWTYPE;
  v_similarity real;
  v_review_required boolean := false;
BEGIN
  IF coalesce(btrim(p_source_event_id), '') = '' THEN RAISE EXCEPTION 'source_event_id is required'; END IF;
  IF char_length(btrim(coalesce(p_text, ''))) < 10 THEN
    INSERT INTO tickets (source_event_id, raw_text, received_at, disposition)
    VALUES (p_source_event_id, coalesce(p_text, ''), coalesce(p_received_at, now()), 'rejected_invalid')
    ON CONFLICT (source_event_id) DO NOTHING RETURNING id INTO v_ticket_id;
    IF v_ticket_id IS NULL THEN SELECT id INTO v_ticket_id FROM tickets WHERE source_event_id = p_source_event_id; RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'duplicate', NULL::real, false; ELSE RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'rejected_invalid', NULL::real, false; END IF;
    RETURN;
  END IF;
  IF p_embedding IS NULL OR coalesce(btrim(p_embedding_model), '') = '' THEN RAISE EXCEPTION 'embedding and embedding_model are required for a valid ticket'; END IF;

  -- One model-level lock prevents competing cluster selection, count refresh,
  -- and verification claims while retaining parallelism across model versions.
  PERFORM pg_advisory_xact_lock(hashtextextended('ticket_cluster:ingest:' || p_embedding_model, 0));

  INSERT INTO tickets (source_event_id, raw_text, received_at, embedding_model, embedding)
  VALUES (p_source_event_id, p_text, coalesce(p_received_at, now()), p_embedding_model, p_embedding)
  ON CONFLICT (source_event_id) DO NOTHING RETURNING id INTO v_ticket_id;
  IF v_ticket_id IS NULL THEN
    SELECT t.id, ct.cluster_id, ct.assignment_similarity INTO v_ticket_id, v_cluster_id, v_similarity
    FROM tickets t LEFT JOIN cluster_tickets ct ON ct.ticket_id = t.id WHERE t.source_event_id = p_source_event_id;
    RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'duplicate', v_similarity, false; RETURN;
  END IF;

  SELECT c.* INTO v_cluster FROM clusters c
  WHERE c.embedding_model = p_embedding_model
    AND c.status IN ('active', 'verification_pending', 'pending_review', 'needs_review', 'approved', 'alerted')
  ORDER BY c.seed_embedding <=> p_embedding LIMIT 1;

  IF FOUND AND (1 - (v_cluster.seed_embedding <=> p_embedding))::real >= v_cluster.assignment_threshold THEN
    v_cluster_id := v_cluster.id;
    v_similarity := (1 - (v_cluster.seed_embedding <=> p_embedding))::real;
  ELSE
    INSERT INTO clusters (seed_ticket_id, embedding_model, seed_embedding, centroid_embedding, assignment_threshold, verification_threshold, alert_threshold)
    VALUES (v_ticket_id, p_embedding_model, p_embedding, p_embedding, p_assignment_threshold, p_verification_threshold, p_alert_threshold)
    RETURNING id INTO v_cluster_id;
    v_similarity := 1.0;
  END IF;

  INSERT INTO cluster_tickets (cluster_id, ticket_id, assignment_similarity) VALUES (v_cluster_id, v_ticket_id, v_similarity);
  UPDATE tickets SET disposition = 'clustered' WHERE id = v_ticket_id;
  UPDATE clusters c SET ticket_count = counts.ticket_count, centroid_embedding = counts.centroid_embedding, updated_at = now()
  FROM (
    SELECT ct.cluster_id, count(*)::integer AS ticket_count, avg(t.embedding) AS centroid_embedding
    FROM cluster_tickets ct JOIN tickets t ON t.id = ct.ticket_id WHERE ct.cluster_id = v_cluster_id GROUP BY ct.cluster_id
  ) counts WHERE c.id = counts.cluster_id;

  UPDATE clusters
  SET status = 'verification_pending', updated_at = now()
  WHERE id = v_cluster_id AND status = 'active' AND ticket_count >= verification_threshold
  RETURNING true INTO v_review_required;
  v_review_required := coalesce(v_review_required, false);
  IF v_review_required THEN
    INSERT INTO workflow_runs (source_event_id, workflow_version, stage, outcome)
    VALUES (p_source_event_id, p_workflow_version, 'assignment', 'verification_required');
  END IF;
  RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'clustered', v_similarity, v_review_required;
END;
$$;
