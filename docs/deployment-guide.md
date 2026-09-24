# Reproducible deployment guide

This guide uses supported n8n UI actions for import, publishing, activation,
and credential attachment. Do not edit n8n database tables to activate a
workflow. Do not export credential-bearing workflows.

## 1. Validate and create staging

On the server in the project directory:

```bash
git checkout production-hardening/outbox-review-integrity
node scripts/validate-production-foundation.mjs
scripts/create-staging-database.sh n8n_staging
scripts/apply-migrations.sh n8n_staging
```

The creation script refuses to overwrite a database. Use a new staging name
for a new test run; do not delete a database unless its exact target and backup
have been reviewed.

## 2. Prepare workflow files without credentials

Use a temporary directory outside the repository. The command below accepts
only non-secret IDs. It refuses API keys, tokens, passwords, and secrets.

```bash
node scripts/prepare-n8n-import.mjs \
  --input workflows/operational-monitor.template.json \
  --output /tmp/operational-monitor.import.json \
  --workflow-id REPLACE_WITH_NEW_N8N_WORKFLOW_ID \
  --set REPLACE_WITH_OPERATIONS_CHANNEL_ID=REPLACE_WITH_SLACK_CHANNEL_ID
```

Prepare the other workflows the same way. Keep each generated import file
private and remove it after the n8n UI import is complete.

## 3. Import and publish in n8n

For every workflow:

1. Open n8n and select **Import from File**.
2. Import the generated JSON while it is inactive.
3. Attach the existing credential through the node UI. Credential values are
   never entered in JSON:
   - Slack nodes: the credential backed by `SLACK_BOT_TOKEN`.
   - Gemini nodes: the credential backed by `GEMINI_API_KEY`.
   - OpenRouter nodes: the credential backed by `OPENROUTER_API_KEY`.
   - Google Docs/Sheets nodes: the credential backed by
     `GOOGLE_SERVICE_ACCOUNT_JSON` or the approved OAuth account.
   - Postgres nodes: the credential backed by `POSTGRES_PASSWORD`.
   - Telegram nodes: a native Telegram API credential backed by
     `TELEGRAM_BOT_TOKEN`. Telegram webhook validation uses the container-only
     `TELEGRAM_WEBHOOK_SECRET`.
4. Select referenced sub-workflows by their imported n8n workflow ID.
5. Click **Publish**, then turn **Active** on. Confirm the UI shows an active
   production workflow, not “Listen for test event.”

Import order: error capture; operational monitor; report-delivery worker;
approval handler; cluster-review; Telegram interface; core Slack intake. Configure the error-capture
workflow as **Error Workflow** in each production workflow’s Settings.

## 4. Staging acceptance tests

Run the SQL and static checks, then carry out one real staging event:

```bash
node tests/test_delivery_workflow.mjs
node tests/test_telegram_interface.mjs
node scripts/validate-production-foundation.mjs
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_review_integrity.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_outbox_state_machine.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_operational_observability.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_privacy_retention.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_recurrence_episodes.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_pilot_readiness_gates.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_incident_lifecycle.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_investigation_cards.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_telegram_interface.sql
docker compose exec -T -e TEST_DATABASE_URL=postgresql://n8n@localhost/n8n_staging postgres bash -s < tests/test_ingestion_concurrency.sh
```

Only promote after the approval callback, Docs, Sheets, engineering alert,
one failed-stage recovery, and one incident notification all pass in staging.

## 5. Production promotion and rollback

Take a protected database backup before applying a new migration. Apply only
forward migrations after staging passes. Keep the prior workflow version
published but inactive until the post-promotion test passes. If promotion
fails, deactivate the new workflow in the n8n UI and reactivate the previous
published version; preserve execution IDs and incident records for diagnosis.
