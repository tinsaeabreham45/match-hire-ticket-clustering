# n8n workflow import notes

The n8n implementation is split into four inactive, credential-free imports:

1. `support-ticket-clustering.template.json` — Slack ticket intake, validation, Gemini embedding, idempotent seed-anchor assignment, and the sub-workflow call.
2. cluster-review.template.json — evidence lookup, structured OpenRouter verification/report drafting with Gemini fallback on provider or strict-JSON failure, database persistence, and Slack Block Kit review card.
3. `approval-handler.template.json` — signed Slack action callback, auditable approve/reject/split decision, Google Doc/Sheet delivery, and post-approval engineering notification.
4. requeue-cluster-verification.template.json — operator-only manual recovery for a cluster whose prior verification completed in a safe needs_review state.

Import all three before configuring any credential or activating a workflow.

## Required configuration

- Attach `SLACK_BOT_TOKEN` to the Slack Trigger and the HTTP Request nodes which post Slack messages.
- Attach `GEMINI_API_KEY` as HTTP Header Auth (`x-goog-api-key`) to the Gemini node. Do not place it in a node field or workflow variable.
- Attach that same Gemini Header Auth credential to both nodes named Gemini fallback in the review workflow. The fallback uses gemini-2.5-flash only when OpenRouter has a technical failure or returns invalid structured output; a valid semantic needs_review verdict never triggers fallback.
- Attach the existing Postgres credential; apply the SQL migration first and use schema-qualified calls (`ticket_cluster.ingest_ticket`).
- Replace the `REPLACE_WITH_*` channel, model, Google Sheet, and sub-workflow identifiers after import. These are configuration, not credentials; keep an operator record of them.
- Configure an n8n error workflow or error trigger for HTTP/429/5xx, database failures, and invalid JSON/embeddings. Its message must name the execution URL and event ID but not expose ticket text unnecessarily.
- In the core workflow, select the imported **Cluster verification and triage draft** workflow in **Run verification and triage sub-workflow**. It receives the current `cluster_id` item.
- For the approval handler, expose `SLACK_SIGNING_SECRET` only to the n8n container as a server-side environment variable and permit the built-in `crypto` module for the Code node. Slack's signature cannot be securely checked from a normal HTTP credential field alone.
- Configure Google Docs/Sheets credentials after confirming this n8n version supports your planned service-account method. Create a `Cluster Log` worksheet with headers before enabling the Sheets node.

## Safe import order and activation test

1. Apply `001_cluster_schema.sql`. If you applied it before this update, also apply `002_report_drafts.sql`.
2. Import the three workflows in the order above. Keep all inactive.
3. Add only the plan's placeholder credentials in n8n; attach them to the annotated nodes. Do not send values to this repository or chat.
4. Set the imported review workflow in the core sub-workflow node, then set Slack Interactivity to the approval handler's **production** webhook URL.
5. Run TC-01 to TC-03. Confirm a pending Slack review card is created and no engineering alert is posted.
6. Test an OpenRouter 429/5xx or malformed result: Gemini should produce the verification/report instead. Test both providers unavailable: no approval card or engineering alert may be sent.
7. Test invalid model JSON, invalid/stale Slack signature, replayed callback, reject, split, and approve. Only then activate the core workflow.

## Version compatibility note

n8n node parameter shapes can differ by version. If import flags a node property, recreate just that node in the n8n UI using the values and order above; preserve the safety conditions and SQL function calls rather than copying credentials into the exported JSON.
