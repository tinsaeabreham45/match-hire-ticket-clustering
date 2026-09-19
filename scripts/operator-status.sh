#!/usr/bin/env bash
set -euo pipefail

database_name="${1:-n8n}"
exec docker compose exec -T postgres psql -P pager=off -U n8n -d "$database_name" <<'SQL'
SELECT c.status AS cluster_status, count(*) AS clusters
FROM ticket_cluster.clusters c
GROUP BY c.status
ORDER BY c.status;

SELECT a.target, a.status, count(*) AS delivery_attempts
FROM ticket_cluster.delivery_attempts a
GROUP BY a.target, a.status
ORDER BY a.target, a.status;

SELECT d.id AS report_draft_id, c.id AS cluster_id, d.status AS draft_status,
       c.status AS cluster_status, d.updated_at
FROM ticket_cluster.cluster_report_drafts d
JOIN ticket_cluster.clusters c ON c.id = d.cluster_id
WHERE d.status IN ('pending_review', 'delivery_pending')
ORDER BY d.updated_at ASC
LIMIT 20;
SQL
