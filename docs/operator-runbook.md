# Operator runbook

## Purpose and ownership

Operate the synthetic-ticket clustering demo safely. The support lead owns approval decisions; the operator owns n8n, Postgres state, integration health, and demo-data cleanup. Engineering alerts must remain disabled until the approval path is tested.

## Pre-flight checklist

1. Confirm the EC2 n8n endpoint is HTTPS-reachable and the Postgres/pgvector service is healthy.
2. Apply migrations `docs/sql/001_cluster_schema.sql` through `docs/sql/012_investigation_cards.sql` in numeric order to staging first; confirm the `ticket_cluster` schema and `vector` extension exist.
3. In n8n's credential store, add the required integration credentials. Never paste their values into workflow fields, exports, logs, or this repository.
4. Import all inactive templates in `workflows/`: core intake, cluster review, approval handler, and report-delivery worker. In the core workflow select the imported review sub-workflow by ID; in the approval workflow select the imported delivery worker by ID.
5. Attach the appropriate Slack, Postgres, Gemini, OpenRouter, Google Docs, and Google Sheets credentials; replace every `REPLACE_WITH_*` configuration value; import the operational error-capture workflow; and select it as the Error Workflow for every production workflow.
6. Confirm Google Docs/Sheets authentication works in this n8n version before enabling their nodes. Document the supported method in the runbook before handoff.
7. Expose `SLACK_SIGNING_SECRET` only as a server-side n8n environment variable and allow the Code node's built-in `crypto` module. Configure Slack Interactivity to the approval handler's HTTPS production webhook, then test valid, stale, and replayed callbacks.
8. Insert the support lead's Slack member ID into `ticket_cluster.authorized_approvers`. Do not activate approvals while the allowlist is empty.

## Dry run then activation

1. Run `python3 scripts/ticket_simulator.py --dry-run`; verify the printed case order.
2. In n8n, manually execute a representative event and confirm one row is written to `tickets`, a vector has 768 dimensions, and the cluster seed equals the first ticket vector.
3. Post TC-01 through TC-03 with `python3 scripts/ticket_simulator.py --post --limit 3`. Confirm no `#eng-alerts` post occurs, even if the verification draft is ready.
4. Exercise invalid input, invalid LLM JSON, rejected/split action, replayed callback, and approved action. Only after every safe result is recorded may the workflow be activated.
5. For the hardening branch, test a non-approver action, report-draft mismatch, and failed Docs/Sheets/Slack delivery. Confirm the report remains `delivery_pending` until the outbox worker completes all three stages.

## Routine operation

- Review `pending_review` clusters in `#support-triage`; approve only when the evidence ticket IDs support one concrete root cause.
- Treat `needs_review`, `embedding_failed`, and document-delivery failures as operator work. Reprocess only after fixing the root cause and preserve the original execution record.
- Monitor n8n error executions and Postgres `workflow_runs`. Errors need an event ID, stage, and operator-facing action; avoid sending full ticket text to general channels.
- Run `scripts/operator-status.sh` from the server project directory at the beginning of each shift and after any failed external delivery. Review open `operational_incidents`; acknowledge only after assigning an owner and next action.
- Run `SELECT ticket_cluster.redact_expired_ticket_content();` on the approved retention cadence. Test this against staging first: it permanently removes stored ticket text and ticket embeddings after the retention period.
- Treat each recurrence episode as a new review boundary. Episode 1 reports remain immutable; after the configured cooldown, a matching issue opens the next linked episode and must independently cross the review threshold.
- Treat `verification_attention` as a one-time operator warning for a valid low-confidence `needs_review` result. A repeating `verification_stuck` error means no model decision was recorded and requires workflow recovery.
- A **Root-cause investigation required** card is not an engineering approval. **Retry verification** reruns the same stored evidence, **Dismiss** closes without delivery, and **Split cluster** records that the grouping was incorrect. Only authorized reviewers may use these actions.
- Record every evaluation run in `docs/evaluation.md` or the designated Sheet, including model and threshold versions.

## Incident handling

| Symptom | Immediate safe action | Follow-up |
|---|---|---|
| Unapproved engineering alert | Disable workflow, preserve execution IDs, notify the support lead, and investigate approval/audit records. | Add a regression test before reactivation. |
| Wrong merge | Reject or split the cluster; do not alert engineering. | Review threshold/test data and log before/after result. |
| OpenRouter failure or invalid structured output | Let bounded retries finish; Gemini 2.5 Flash should run once as the fallback. Never send an approval card until a valid structured response passes validation. | Check provider status and the review execution. If Gemini also fails, the cluster remains needs_review; use the operator requeue workflow after recovery rather than creating duplicate tickets. |
| Slack callback invalid/replayed | Reject the action and retain an audit/error event. | Verify raw-body signature handling and timestamp tolerance. |
| Docs/Sheets delivery failure | Keep approved payload and notify operator; do not silently drop it. | Retry delivery after fixing integration; update the record. |
| Operational incident | Use its incident key, execution ID, and target to identify the failed boundary. Do not paste ticket content into operations chat. | Acknowledge with an owner/note, correct the dependency, then requeue only the failed stage. |
| Secret exposed | Revoke/rotate it immediately and remove it from history/logs as appropriate. | Document the incident without reproducing the secret. |

## Demo data retention

This demo stores only synthetic tickets. At the end of the sprint (or within 30 days), export the evaluation evidence needed for the case study, then delete the synthetic rows/docs/sheet entries using a reviewed, target-specific procedure. Do not run broad destructive commands against the shared Postgres instance.
