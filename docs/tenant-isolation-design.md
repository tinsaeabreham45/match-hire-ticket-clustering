# Tenant isolation design

The current system is single tenant. The `default` deployment must not accept
data from a second company until this design is implemented and tested.

## Required data boundary

Every customer-scoped record receives `tenant_id`: tickets, clusters,
cluster-ticket assignments, verification results, report drafts, review
actions, delivery attempts, workflow runs, and operational incidents. Every
unique source event key becomes `(tenant_id, source_event_id)`.

Every database function must accept or resolve a tenant ID and include it in
all reads, writes, locks, and conflict handling. The advisory lock scope becomes
`tenant_id + embedding_model`; otherwise two customers could serialize each
other or share a cluster.

## Required configuration boundary

Per-tenant configuration owns:

- allowed Slack workspace/channel and approvers;
- future Telegram chat/user allowlists;
- future email provider routing address/domain;
- thresholds, model version, data-retention policy, and operations channel;
- separately stored n8n credentials and Google destinations.

## Required access boundary

Use a service identity restricted to one tenant for runtime operations, plus
admin-only cross-tenant reporting. Enable and test PostgreSQL row-level
security only after every existing query is tenant-scoped. A global n8n owner
account is not sufficient for a multi-customer product.

## Migration sequence

1. Create `tenants` and configuration tables; create one `default` tenant.
2. Add nullable `tenant_id` columns and backfill all current records.
3. Add tenant-scoped indexes and foreign keys.
4. Replace functions and workflows to carry `tenant_id` from the connector.
5. Remove global uniqueness and global approver/channel assumptions.
6. Enable RLS and run cross-tenant negative tests.
7. Only then onboard a second tenant.

This sequence is intentionally separate from privacy/retention. Adding a
tenant column without tenant-scoped functions would create false confidence.
