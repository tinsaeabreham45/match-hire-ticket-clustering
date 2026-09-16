-- Apply this only when 001_cluster_schema.sql was applied before the
-- cluster_report_drafts table was added to the project.
CREATE TABLE IF NOT EXISTS ticket_cluster.cluster_report_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id uuid NOT NULL REFERENCES ticket_cluster.clusters(id) ON DELETE CASCADE,
  verification_id uuid REFERENCES ticket_cluster.cluster_verifications(id) ON DELETE SET NULL,
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
CREATE INDEX IF NOT EXISTS cluster_report_drafts_cluster_idx
  ON ticket_cluster.cluster_report_drafts (cluster_id, created_at DESC);
