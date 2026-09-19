#!/usr/bin/env bash
set -euo pipefail

: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to an isolated database, never the live database.}"

model="hardening-concurrency-$(date +%s%N)"
vector="array_prepend(1::real, array_fill(0::real, ARRAY[767]))::vector"
sql_a="SELECT ticket_id, cluster_id, review_required FROM ticket_cluster.ingest_ticket('hardening-concurrent-a-${model}', 'Concurrent synthetic ticket A for one shared outage', now(), ${vector}, '${model}', 0.84, 2, 2, 'hardening-test');"
sql_b="SELECT ticket_id, cluster_id, review_required FROM ticket_cluster.ingest_ticket('hardening-concurrent-b-${model}', 'Concurrent synthetic ticket B for one shared outage', now(), ${vector}, '${model}', 0.84, 2, 2, 'hardening-test');"

psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "$sql_a" >/tmp/hardening-concurrent-a.out &
pid_a=$!
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "$sql_b" >/tmp/hardening-concurrent-b.out &
pid_b=$!
wait "$pid_a"
wait "$pid_b"

result="$(psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "SELECT count(*) || '|' || max(ticket_count) || '|' || count(*) FILTER (WHERE status = 'verification_pending') FROM ticket_cluster.clusters WHERE embedding_model = '${model}';")"
if [[ "$result" != "1|2|1" ]]; then
  echo "FAIL: expected one cluster, two tickets, one verification claim; got ${result}" >&2
  exit 1
fi

psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM ticket_cluster.clusters WHERE embedding_model = '${model}'; DELETE FROM ticket_cluster.tickets WHERE source_event_id IN ('hardening-concurrent-a-${model}', 'hardening-concurrent-b-${model}');" >/dev/null
echo "PASS: concurrent ingestion produced one cluster and one verification claim"
