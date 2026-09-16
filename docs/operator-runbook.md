# Operator runbook

## Purpose and ownership

Operate the synthetic-ticket clustering demo safely. The support lead owns approval decisions; the operator owns n8n, Postgres state, integration health, and demo-data cleanup. Engineering alerts must remain disabled until the approval path is tested.

## Pre-flight checklist

1. Confirm the EC2 n8n endpoint is HTTPS-reachable and the Postgres/pgvector service is healthy.
2. Apply `docs/sql/001_cluster_schema.sql` once; confirm the `ticket_cluster` schema and `vector` extension exist.
3. In n8n's credential store, add only the placeholder credentials listed in the system plan. Never paste their values into workflow fields, exports, logs, or this repository.
4. Import all three inactive templates in `workflows/`: core intake, cluster review, and approval handler. In the core workflow select the imported review sub-workflow by ID.
5. Attach the appropriate Slack, Postgres, Gemini, and OpenRouter credentials; replace every `REPLACE_WITH_*` configuration value; and configure an error workflow.
6. Confirm Google Docs/Sheets authentication works in this n8n version before enabling their nodes. If it does not, update the system plan with the supported method; do not invent a new untracked credential.
7. Expose `SLACK_SIGNING_SECRET` only as a server-side n8n environment variable and allow the Code node's built-in `crypto` module. Configure Slack Interactivity to the approval handler's HTTPS production webhook, then test valid, stale, and replayed callbacks.

## Dry run then activation

1. Run `python3 scripts/ticket_simulator.py --dry-run`; verify the printed case order.
2. In n8n, manually execute a representative event and confirm one row is written to `tickets`, a vector has 768 dimensions, and the cluster seed equals the first ticket vector.
3. Post TC-01 through TC-03 with `python3 scripts/ticket_simulator.py --post --limit 3`. Confirm no `#eng-alerts` post occurs, even if the verification draft is ready.
4. Exercise invalid input, invalid LLM JSON, rejected/split action, replayed callback, and approved action. Only after every safe result is recorded may the workflow be activated.

## Routine operation

- Review `pending_review` clusters in `#support-triage`; approve only when the evidence ticket IDs support one concrete root cause.
- Treat `needs_review`, `embedding_failed`, and document-delivery failures as operator work. Reprocess only after fixing the root cause and preserve the original execution record.
- Monitor n8n error executions and Postgres `workflow_runs`. Errors need an event ID, stage, and operator-facing action; avoid sending full ticket text to general channels.
- Record every evaluation run in `docs/evaluation.md` or the designated Sheet, including model and threshold versions.

## Incident handling

| Symptom | Immediate safe action | Follow-up |
|---|---|---|
| Unapproved engineering alert | Disable workflow, preserve execution IDs, notify the support lead, and investigate approval/audit records. | Add a regression test before reactivation. |
| Wrong merge | Reject or split the cluster; do not alert engineering. | Review threshold/test data and log before/after result. |
| OpenRouter failure or invalid structured output | Let bounded retries finish; Gemini 2.5 Flash should run once as the fallback. Never send an approval card until a valid structured response passes validation. | Check provider status and the review execution. If Gemini also fails, the cluster remains needs_review; use the operator requeue workflow after recovery rather than creating duplicate tickets. |
| Slack callback invalid/replayed | Reject the action and retain an audit/error event. | Verify raw-body signature handling and timestamp tolerance. |
| Docs/Sheets delivery failure | Keep approved payload and notify operator; do not silently drop it. | Retry delivery after fixing integration; update the record. |
| Secret exposed | Revoke/rotate it immediately and remove it from history/logs as appropriate. | Document the incident without reproducing the secret. |

## Demo data retention

This demo stores only synthetic tickets. At the end of the sprint (or within 30 days), export the evaluation evidence needed for the case study, then delete the synthetic rows/docs/sheet entries using a reviewed, target-specific procedure. Do not run broad destructive commands against the shared Postgres instance.
