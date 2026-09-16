# n8n UI setup — exact import and configuration steps

Keep all workflows **inactive** until the final test section passes. Never paste secrets into a workflow node, exported JSON, repository file, or chat.

## 1. Import the workflows

At `https://16.170.93.79.nip.io`:

1. Sign in as the n8n owner.
2. In the left navigation, select **Workflows**.
3. Select the arrow beside **Create Workflow** (or the `…` menu) and choose **Import from File**.
4. Import, one at a time and in this exact order:
   - `workflows/cluster-review.template.json`
   - `workflows/approval-handler.template.json`
   - `workflows/requeue-cluster-verification.template.json`
   - `workflows/support-ticket-clustering.template.json`
5. For each import, keep the top-right **Active/Published** switch off and select **Save**.
6. Return to the core workflow. Click **Run verification and triage sub-workflow**. In **Workflow**, select the imported workflow named **Cluster verification and triage draft (template)**. Save.

The core must be imported last because it references the review workflow by its n8n workflow ID.

## 2. Create credentials

Create credentials from the specific node that will consume them: click the node, open its **Credential to connect with** field, and select **Create new credential**. That avoids choosing an incompatible generic credential type.

| Credential label to use | Credential type and fields | Attach to nodes |
|---|---|---|
| `SLACK_BOT_TOKEN` | For **Slack ticket received**, create the Slack credential offered by that node and enter the bot token. For HTTP Request Slack posts, create **Header Auth**: header `Authorization`, value `Bearer <rotated bot token>`. | Core: `Slack ticket received`. Review: `Post human approval card`. Approval: `Notify engineering after approval`. |
| `GEMINI_API_KEY` | **Header Auth**: header `x-goog-api-key`, value is the Gemini API key. | Core: `Embed ticket with Gemini`. Review: Verify root cause with Gemini fallback; Draft report with Gemini fallback. |
| `OPENROUTER_API_KEY` | **Header Auth**: header `Authorization`, value `Bearer <OpenRouter key>`. | Review: `Verify root cause with OpenRouter`; `Draft report with OpenRouter`. |
| `POSTGRES_PASSWORD` | The **Postgres** credential offered by a Postgres node. Use host `postgres` (inside Compose), port `5432`, database `n8n`, user `n8n`, and the existing password. | Core: `Assign seed-anchored cluster`, `Record invalid ticket`. Review: `Load cluster evidence`, `Persist verification`, `Persist pending report draft`. Approval: `Record auditable human decision`, `Load approved draft`, `Mark report delivered and cluster alerted`, `Close rejected or split draft`. |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Choose **Google Service Account API** in the Google Docs and Google Sheets node credential selector. In the JSON key, use `client_email` as Service Account Email and `private_key` as Private Key. Enable Google Docs API, Google Sheets API, and Google Drive API; share the target Sheet/folder with the service-account email. | Approval: `Create approved Google Doc`; `Append approved audit row to Sheets`. |

`SLACK_SIGNING_SECRET` is not attached to a node credential: it must be a server-side n8n container environment variable because the approval callback validates an HMAC over the raw HTTP body. Also set `NODE_FUNCTION_ALLOW_BUILTIN=crypto` in the n8n service environment. Do not enter either value in workflow JSON or a Code node.

## 3. Replace configuration placeholders

| Placeholder | Where | Exact value and how to obtain it |
|---|---|---|
| `REPLACE_WITH_IMPORTED_CLUSTER_REVIEW_WORKFLOW_ID` | Core → `Run verification and triage sub-workflow` | Do not type an ID. Click the node and select **Cluster verification and triage draft (template)** from the workflow picker. |
| `REPLACE_WITH_OPENROUTER_VERIFICATION_MODEL` | Review → `Build verification request` Code node | Replace with the OpenRouter model slug you selected for verification, for example a low-cost JSON-capable model slug shown in your OpenRouter Models page. Use the exact slug, not its display name. |
| `REPLACE_WITH_OPENROUTER_REPORT_MODEL` | Review → `Build report request` Code node | Replace with the selected JSON-capable report-drafting model slug. It may be the same as verification. |
| `REPLACE_WITH_SUPPORT_TRIAGE_CHANNEL_ID` | Review → `Build Slack approval card` Code node | Slack desktop/web: open `#support-triage` → click the channel name → scroll to the bottom of **About** → copy **Channel ID**. Paste the ID, not `#support-triage`. |
| `REPLACE_WITH_GOOGLE_SHEET_ID` | Approval → `Append approved audit row to Sheets` | Open the target Sheet. Copy the part between `/d/` and `/edit` in its URL. Create a tab named `Cluster Log` with headers matching the fields passed by `Prepare delivery audit row`, then refresh the node’s column mapping. |
| `REPLACE_WITH_ENGINEERING_ALERTS_CHANNEL_ID` | Approval → `Build engineering alert` Code node | Slack: open `#eng-alerts` → channel name → **About** → copy **Channel ID**. Paste the ID, not the channel name. |
| REPLACE_WITH_CLUSTER_ID_TO_REQUEUE | Requeue workflow → Set cluster to requeue Code node | Only when recovering a completed provider failure: query the cluster ID in Postgres or copy it from the review execution. Replace the UUID, run manually, then restore the placeholder before saving. |

You may provide only these non-secret IDs/model slugs in chat if you want the JSON edited before importing. Do not provide any token, private key, password, or signing secret.

## 4. Configure Slack events and Interactivity

### Ticket events

1. In n8n core, click `Slack ticket received`, select the event **New Message Posted to Channel**, attach `SLACK_BOT_TOKEN`, and save.
2. In Slack, open your app configuration → **Event Subscriptions** → turn **Enable Events** on.
3. Copy the request URL shown by the Slack Trigger node after it is saved/activated and paste it into Slack’s **Request URL** field.
4. Under **Subscribe to bot events**, add `message.channels`; save changes and reinstall the app if Slack asks.
5. Invite the Slack app to `#support-tickets` and confirm the simulator’s bot messages are delivered to n8n.

### Human approval buttons

1. Open the imported **Slack approval and report delivery (template)** workflow.
2. Click `Slack approval callback`. The path is `slack-cluster-approval`.
3. Save the workflow. Its production URL is `https://16.170.93.79.nip.io/webhook/slack-cluster-approval` (do not use the `/webhook-test/` URL).
4. In Slack app configuration → **Interactivity & Shortcuts**, turn **Interactivity** on.
5. Paste that production URL into **Request URL**, select **Save Changes**, and reinstall the app if prompted.

## 5. Test TC-01 through TC-03 before activation

1. Verify the core workflow is saved but inactive. In n8n, open its `Slack ticket received` node and use its test/listen mode if your version requires it.
2. On the local machine holding this repository, run the simulator for the first three valid tickets after the Slack credential and support-channel ID are configured: `python3 scripts/ticket_simulator.py --post --limit 3`.
3. In n8n’s left navigation, open **Executions**. Filter by the core workflow and open each execution:
   - TC-01: `Assign seed-anchored cluster` returns `clustered`, `review_required: false`.
   - TC-02: joins the same `cluster_id`, `review_required: false`.
   - TC-03: joins that `cluster_id`, `review_required: true`; the review sub-workflow runs.
4. Open the review workflow execution. Confirm `Persist verification` returns `pending_review`, then confirm `Post human approval card` returns Slack `ok: true`.
5. Confirm `#eng-alerts` has **no** message. A card should appear only in `#support-triage`.
6. Before activating core, click **Reject** once and verify the approval workflow records `rejected` and does not create a Doc, Sheet row, or engineering alert. Then repeat with a test cluster and approve only after the safety tests in the operator runbook pass.

If an execution fails, open the failed node’s **Error** tab, record the n8n execution URL and node name in `docs/evaluation.md`, and keep the workflow inactive while fixing it.

## 6. Provider fallback and manual recovery

The review workflow treats an OpenRouter HTTP 429/5xx, error payload, missing content, or invalid strict JSON as a technical failure. It calls Gemini 2.5 Flash with the same evidence and a JSON schema. A valid OpenRouter needs_review verdict is a human-review decision, not a provider failure, so Gemini is not called.

If both providers fail during verification, the cluster safely remains needs_review. If the prior execution is marked **Success**, n8n has no Retry button because the workflow intentionally stopped safely. Import the inactive requeue workflow, select the review workflow in Run cluster review again, replace its cluster UUID placeholder, and click **Execute Workflow**. It reuses stored evidence and does not create another support ticket.
