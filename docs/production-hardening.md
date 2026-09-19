# Production hardening: delivery integrity, operations, and privacy

This branch hardens the correctness boundaries discovered during prototype
testing and adds the operational foundations needed to run them safely. It is
not deployed to the live server by default.

## What changes

| Risk | Protection |
|---|---|
| Slack notification fails after state says delivered | An outbox records the Docs, Sheets, and engineering-Slack stages separately. Only three confirmed successes finalize delivery. |
| Any Slack member can approve | The database checks an active approver allowlist, and the workflow checks the expected Slack workspace and triage channel. |
| Simultaneous tickets race cluster assignment | A transaction-scoped PostgreSQL advisory lock serializes assignment per embedding model. |
| A workflow failure is invisible or repeated | A sanitized incident ledger, rate-limited operations alerts, and an acknowledgement trail make failures reviewable. |
| Ticket text retains common PII indefinitely | Write-time redaction removes common email, phone, and card patterns before persistence or embedding; a retention job later removes remaining ticket content. |

## Migration order

Apply these once, in order, to an isolated staging database first:

1. `001_cluster_schema.sql`
2. `002_report_drafts.sql`
3. `003_function_search_path.sql`
4. `004_delivery_outbox.sql`
5. `005_review_integrity.sql`
6. `006_ingestion_serialization.sql`
7. `007_operational_observability.sql`
8. `008_privacy_retention.sql`

Migration `005` creates an empty approver allowlist. Before enabling the
approval workflow, add the support lead's Slack member ID and the existing
workspace/triage-channel pair using these commands in a secure server terminal:

```sql
INSERT INTO ticket_cluster.authorized_approvers (slack_user_id)
VALUES ('REPLACE_WITH_SUPPORT_LEAD_SLACK_USER_ID');

INSERT INTO ticket_cluster.authorized_review_contexts (slack_workspace_id, slack_channel_id)
VALUES ('REPLACE_WITH_SLACK_WORKSPACE_ID', 'REPLACE_WITH_SUPPORT_TRIAGE_CHANNEL_ID');
```

This value is an identifier, not a secret. Do not put it in source code.

## New workflow import order

1. Import `workflows/report-delivery.template.json` and keep it inactive.
2. Copy its workflow ID.
3. Import `workflows/approval-handler.template.json`.
4. In `Run queued delivery worker`, select the imported delivery workflow.
5. In `Validate workspace and triage channel`, replace the workspace and
   `#support-triage` channel placeholders with IDs from the existing Slack app.
6. Attach the existing Postgres, Google Docs, Google Sheets, and Slack
   credentials to their annotated nodes. Do not export or paste secrets.
7. Activate the delivery worker first, then activate the approval workflow.

## Delivery behavior

An approved draft is first changed to `delivery_pending` and receives three
unique outbox rows. The worker claims one ordered stage at a time:

1. Google Doc creation, content write, and read-back verification.
2. Google Sheets audit append.
3. Engineering Slack post with Slack `ok: true` verification.

The report becomes `delivered` and the cluster becomes `alerted` only after
stage three succeeds. If a worker stops before a checkpoint, the lease expires
after 15 minutes and the stage becomes eligible for retry. This deliberately
favors manual reconciliation over rapid duplicate external writes.

## Required staging tests

1. A non-allowlisted Slack user clicks Approve: no report state changes.
2. The same Slack callback is replayed: no duplicate delivery rows exist.
3. The callback references a different report draft: no report state changes.
4. Force each external stage to fail: the report remains `delivery_pending`.
5. Restore the integration and run the worker: it resumes at the failed stage.
6. Send concurrent tickets with the same embedding model: one review claim is
   made at the threshold crossing.

Do not apply these migrations to production until every staging result is
recorded and reviewed. For the supported staging setup, workflow import order,
and rollback process, follow [`deployment-guide.md`](deployment-guide.md).
