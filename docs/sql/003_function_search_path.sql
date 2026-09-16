-- Ensure stored functions resolve the application schema when called by n8n.
-- n8n's Postgres credential uses the default `public` search path.

ALTER FUNCTION ticket_cluster.ingest_ticket(
  text, text, timestamptz, vector, text, real, integer, integer, text
) SET search_path = ticket_cluster, public;

ALTER FUNCTION ticket_cluster.record_cluster_verification(
  uuid, text, text, real, text, uuid[], jsonb, real
) SET search_path = ticket_cluster, public;

ALTER FUNCTION ticket_cluster.record_review_action(
  uuid, text, text, text, text
) SET search_path = ticket_cluster, public;
