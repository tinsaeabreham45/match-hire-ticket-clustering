-- Link repeated occurrences of an alerted root cause without mutating its prior report.
-- Apply after 001-008. The default recurrence cooldown is 24 hours per cluster.

SET search_path TO ticket_cluster, public;

ALTER TABLE clusters
  ADD COLUMN IF NOT EXISTS recurrence_group_id uuid,
  ADD COLUMN IF NOT EXISTS episode_number integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS previous_episode_id uuid,
  ADD COLUMN IF NOT EXISTS recurrence_similarity real,
  ADD COLUMN IF NOT EXISTS recurrence_cooldown interval NOT NULL DEFAULT interval '24 hours';

UPDATE clusters
SET recurrence_group_id = gen_random_uuid()
WHERE recurrence_group_id IS NULL;

ALTER TABLE clusters
  ALTER COLUMN recurrence_group_id SET DEFAULT gen_random_uuid(),
  ALTER COLUMN recurrence_group_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clusters_previous_episode_fk') THEN
    ALTER TABLE clusters
      ADD CONSTRAINT clusters_previous_episode_fk
      FOREIGN KEY (previous_episode_id) REFERENCES clusters(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clusters_episode_number_check') THEN
    ALTER TABLE clusters
      ADD CONSTRAINT clusters_episode_number_check CHECK (episode_number > 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clusters_recurrence_similarity_check') THEN
    ALTER TABLE clusters
      ADD CONSTRAINT clusters_recurrence_similarity_check
      CHECK (recurrence_similarity IS NULL OR recurrence_similarity BETWEEN -1 AND 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clusters_recurrence_cooldown_check') THEN
    ALTER TABLE clusters
      ADD CONSTRAINT clusters_recurrence_cooldown_check CHECK (recurrence_cooldown > interval '0 seconds');
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS clusters_recurrence_episode_uidx
  ON clusters (recurrence_group_id, episode_number);
CREATE INDEX IF NOT EXISTS clusters_previous_episode_idx
  ON clusters (previous_episode_id) WHERE previous_episode_id IS NOT NULL;

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
  v_match_similarity real;
  v_review_required boolean := false;
  v_disposition text := 'clustered';
  v_received_at timestamptz := coalesce(p_received_at, now());
BEGIN
  IF coalesce(btrim(p_source_event_id), '') = '' THEN RAISE EXCEPTION 'source_event_id is required'; END IF;
  IF char_length(btrim(coalesce(p_text, ''))) < 10 THEN
    INSERT INTO tickets (source_event_id, raw_text, received_at, disposition)
    VALUES (p_source_event_id, coalesce(p_text, ''), v_received_at, 'rejected_invalid')
    ON CONFLICT (source_event_id) DO NOTHING RETURNING id INTO v_ticket_id;
    IF v_ticket_id IS NULL THEN SELECT id INTO v_ticket_id FROM tickets WHERE source_event_id = p_source_event_id; RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'duplicate', NULL::real, false; ELSE RETURN QUERY SELECT v_ticket_id, NULL::uuid, 'rejected_invalid', NULL::real, false; END IF;
    RETURN;
  END IF;
  IF p_embedding IS NULL OR coalesce(btrim(p_embedding_model), '') = '' THEN RAISE EXCEPTION 'embedding and embedding_model are required for a valid ticket'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('ticket_cluster:ingest:' || p_embedding_model, 0));

  INSERT INTO tickets (source_event_id, raw_text, received_at, embedding_model, embedding)
  VALUES (p_source_event_id, p_text, v_received_at, p_embedding_model, p_embedding)
  ON CONFLICT (source_event_id) DO NOTHING RETURNING id INTO v_ticket_id;
  IF v_ticket_id IS NULL THEN
    SELECT t.id, ct.cluster_id, ct.assignment_similarity INTO v_ticket_id, v_cluster_id, v_similarity
    FROM tickets t LEFT JOIN cluster_tickets ct ON ct.ticket_id = t.id WHERE t.source_event_id = p_source_event_id;
    RETURN QUERY SELECT v_ticket_id, v_cluster_id, 'duplicate', v_similarity, false; RETURN;
  END IF;

  SELECT c.* INTO v_cluster
  FROM clusters c
  WHERE c.embedding_model = p_embedding_model
    AND c.status IN ('active', 'verification_pending', 'pending_review', 'needs_review', 'approved', 'alerted')
    AND NOT EXISTS (
      SELECT 1 FROM clusters newer
      WHERE newer.recurrence_group_id = c.recurrence_group_id
        AND newer.episode_number > c.episode_number
    )
  ORDER BY c.seed_embedding <=> p_embedding, c.episode_number DESC, c.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    v_match_similarity := (1 - (v_cluster.seed_embedding <=> p_embedding))::real;
  END IF;

  IF FOUND AND v_match_similarity >= v_cluster.assignment_threshold THEN
    IF v_cluster.status = 'alerted'
       AND v_cluster.alerted_at IS NOT NULL
       AND v_received_at >= v_cluster.alerted_at + v_cluster.recurrence_cooldown THEN
      INSERT INTO clusters (
        seed_ticket_id, embedding_model, seed_embedding, centroid_embedding,
        assignment_threshold, verification_threshold, alert_threshold,
        recurrence_group_id, episode_number, previous_episode_id,
        recurrence_similarity, recurrence_cooldown
      ) VALUES (
        v_ticket_id, p_embedding_model, p_embedding, p_embedding,
        v_cluster.assignment_threshold, v_cluster.verification_threshold, v_cluster.alert_threshold,
        v_cluster.recurrence_group_id, v_cluster.episode_number + 1, v_cluster.id,
        v_match_similarity, v_cluster.recurrence_cooldown
      ) RETURNING id INTO v_cluster_id;
      v_similarity := 1.0;
      v_disposition := 'new_episode';

      INSERT INTO workflow_runs (source_event_id, workflow_version, stage, outcome, detail)
      VALUES (
        p_source_event_id, p_workflow_version, 'recurrence', 'episode_opened',
        jsonb_build_object(
          'previous_episode_id', v_cluster.id,
          'recurrence_group_id', v_cluster.recurrence_group_id,
          'episode_number', v_cluster.episode_number + 1,
          'recurrence_similarity', v_match_similarity
        )
      );
    ELSE
      v_cluster_id := v_cluster.id;
      v_similarity := v_match_similarity;
    END IF;
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
  UPDATE clusters c SET ticket_count = counts.ticket_count, centroid_embedding = counts.centroid_embedding, updated_at = now()
  FROM (
    SELECT ct.cluster_id, count(*)::integer AS ticket_count, avg(t.embedding) AS centroid_embedding
    FROM cluster_tickets ct JOIN tickets t ON t.id = ct.ticket_id
    WHERE ct.cluster_id = v_cluster_id GROUP BY ct.cluster_id
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
  RETURN QUERY SELECT v_ticket_id, v_cluster_id, v_disposition, v_similarity, v_review_required;
END;
$$;
