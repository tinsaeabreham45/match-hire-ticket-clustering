# Release readiness: security and scalability

## Release decision

This is suitable as a **small, human-reviewed sprint demo** using synthetic tickets. It is not yet a production-scale, unattended support-data service. The distinction is intentional and should be stated in the case study.

## Security review

### Controls present in the repository and workflow design

- Secrets are kept out of templates and source control; `.env`, private-key formats, service-account files, and credential-shaped JSON names are ignored.
- Ticket ingestion is idempotent by stable Slack source event ID, reducing replay/duplicate processing.
- Slack approval callbacks validate the raw request body with `SLACK_SIGNING_SECRET`, a five-minute timestamp window, and constant-time HMAC comparison.
- Approval callback IDs are unique in Postgres, so replayed Slack button actions are recorded once and do not repeat an approval.
- LLM output is schema-validated. Provider outage, invalid output, or uncertain verification routes to a reviewable safe state rather than engineering alerting.
- A human must approve before Google Docs delivery and any engineering notification.
- Database functions use an explicit `ticket_cluster, public` search path and parameterized Postgres-node values.

### Required production hardening before real customer data

1. Restrict n8n administration to named users with MFA/SSO where available; do not expose the editor broadly on the public internet.
2. Keep HTTPS-only ingress. Restrict SSH to a fixed administrator IP or VPN, disable password login, and apply OS/container security updates on a schedule.
3. Keep the Slack event and Interactivity endpoints reachable, but add reverse-proxy rate limits and monitoring for abnormal webhook traffic. Slack signature validation remains the authorization control for button actions.
4. Encrypt and back up Postgres, test restoration, and set n8n execution-data retention. Execution history can contain synthetic ticket text and provider responses.
5. Use separate least-privilege credentials for Slack, Google, model providers, and Postgres. Rotate immediately if a secret is exposed; never place values in exports, logs, or chat.
6. Establish a reviewed, target-specific deletion job before any non-synthetic data is introduced. The current retention statement is synthetic-demo-only.

## Scalability review

### What scales reasonably for the demo

- PostgreSQL has indexes for ticket time, cluster status, report lookup, and an HNSW pgvector index on fixed 768-dimensional seed embeddings.
- Assignment uses a fixed seed embedding instead of a shifting centroid, which keeps the routing decision reproducible as a cluster grows.
- Thresholds, model identifiers, similarity, and workflow version are persisted for debugging and evaluation.
- HTTP model calls have bounded timeouts/retries and Gemini is a bounded fallback to OpenRouter.
- The human approval gate prevents high fan-out alerts while cluster quality is still being calibrated.

### Current limits and scale-up path

| Area | Current demo design | Scale-up action |
|---|---|---|
| Compute | One EC2/n8n process is appropriate for low-volume synthetic traffic. | Use n8n queue mode with Redis and separate workers; size Postgres independently. |
| Model calls | Ticket processing waits for external embedding/model responses. | Introduce a durable queue, concurrency caps, provider quotas, and exponential backoff with a dead-letter/review path. |
| Vector search | HNSW is indexed, but the current clustering query is intentionally simple. | Partition by product/time window, monitor recall/latency, and tune HNSW parameters against labelled evaluation data. |
| Cluster contention | Row locking protects a single cluster update. | Load-test concurrent tickets for the same cluster; add advisory locking or a serialized per-cluster worker if contention appears. |
| Delivery recovery | Approval is auditable; Docs/Sheets delivery must be retried after a failure. | Add a dedicated idempotent outbox/delivery worker and delivery-state dashboard before unattended operation. |
| Observability | n8n executions and Postgres audit tables provide demo-level diagnosis. | Add structured metrics, alerting, log retention/redaction, backup-restore tests, and SLOs. |

## Release checklist

- [x] Workflow JSON and Code-node syntax validated locally.
- [x] Simulator dry-run validated locally.
- [x] Templates contain placeholders rather than secret values.
- [x] SQL includes core indexes and audit/idempotency constraints.
- [x] Recovered the Sheets-delivery execution and verified a recorded Google Doc URL plus delivered report state.
- [x] Completed TC-01 through TC-11 and recorded only observed final-run outcomes in `docs/evaluation.md`.
- [ ] Confirm backups, n8n execution-data retention, and access controls before any real-data pilot.
