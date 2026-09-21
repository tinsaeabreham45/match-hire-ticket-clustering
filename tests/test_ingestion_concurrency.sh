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

recurrence_model="hardening-recurrence-concurrency-$(date +%s%N)"
recurrence_seed_event="hardening-recurrence-seed-${recurrence_model}"
recurrence_a_event="hardening-recurrence-a-${recurrence_model}"
recurrence_b_event="hardening-recurrence-b-${recurrence_model}"

seed_ticket_id="$(psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -qAt -c "INSERT INTO ticket_cluster.tickets (source_event_id, raw_text, embedding_model, embedding, disposition) VALUES ('${recurrence_seed_event}', 'Old alerted synthetic recurrence seed', '${recurrence_model}', ${vector}, 'clustered') RETURNING id;")"
seed_cluster_id="$(psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -qAt -c "INSERT INTO ticket_cluster.clusters (seed_ticket_id, embedding_model, seed_embedding, centroid_embedding, ticket_count, status, alerted_at, verification_threshold, alert_threshold) VALUES ('${seed_ticket_id}', '${recurrence_model}', ${vector}, ${vector}, 1, 'alerted', now() - interval '2 days', 2, 2) RETURNING id;")"
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO ticket_cluster.cluster_tickets (cluster_id, ticket_id, assignment_similarity) VALUES ('${seed_cluster_id}', '${seed_ticket_id}', 1);" >/dev/null

recurrence_sql_a="SELECT ticket_id, cluster_id, review_required FROM ticket_cluster.ingest_ticket('${recurrence_a_event}', 'Concurrent recurrence ticket A for the same returned outage', now(), ${vector}, '${recurrence_model}', 0.84, 2, 2, 'hardening-test');"
recurrence_sql_b="SELECT ticket_id, cluster_id, review_required FROM ticket_cluster.ingest_ticket('${recurrence_b_event}', 'Concurrent recurrence ticket B for the same returned outage', now(), ${vector}, '${recurrence_model}', 0.84, 2, 2, 'hardening-test');"

psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "$recurrence_sql_a" >/tmp/hardening-recurrence-concurrent-a.out &
pid_a=$!
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "$recurrence_sql_b" >/tmp/hardening-recurrence-concurrent-b.out &
pid_b=$!
wait "$pid_a"
wait "$pid_b"

recurrence_result="$(psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "SELECT count(*) || '|' || max(episode_number) || '|' || count(*) FILTER (WHERE episode_number = 2 AND ticket_count = 2 AND status = 'verification_pending') || '|' || count(*) FILTER (WHERE episode_number = 1 AND status = 'alerted') FROM ticket_cluster.clusters WHERE embedding_model = '${recurrence_model}';")"
if [[ "$recurrence_result" != "2|2|1|1" ]]; then
  echo "FAIL: expected one immutable alert and one two-ticket recurrence episode; got ${recurrence_result}" >&2
  exit 1
fi

psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DELETE FROM ticket_cluster.clusters WHERE embedding_model = '${recurrence_model}'; DELETE FROM ticket_cluster.tickets WHERE source_event_id IN ('${recurrence_seed_event}', '${recurrence_a_event}', '${recurrence_b_event}');" >/dev/null
echo "PASS: concurrent recurrence produced one linked episode and one verification claim"
