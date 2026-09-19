# Production foundation plan

This plan turns the working Slack proof of concept into a repeatable, secure
foundation before adding email, Telegram, or helpdesk connectors. It does not
claim production readiness until each acceptance gate is recorded in staging.

## Current boundary

The Slack vertical slice is proven end-to-end: ticket intake, clustering,
model verification, authorized human approval, Google Doc, Google Sheet, and
engineering alert. It is a single-tenant synthetic-data system. The next work
must preserve that decision boundary and make failures visible and recoverable.

## Increment 1 — reproducible deployment and staging

Deliverables:

1. `scripts/validate-production-foundation.mjs` validates workflow imports,
   migration ordering, empty credential exports, and webhook identity.
2. `scripts/prepare-n8n-import.mjs` creates an import-ready copy of a
   workflow, gives it a new n8n workflow ID, and substitutes only non-secret
   `REPLACE_WITH_*` configuration values supplied on the command line.
3. Server-side scripts create an isolated staging database and apply the SQL
   migrations in order. They refuse to overwrite an existing database.
4. The deployment guide uses n8n's supported UI import/publish/activate flow.
   Credential attachment remains a deliberate manual UI step and never enters
   source control.

Acceptance gate: a fresh staging database can be created, migrated, imported,
published, activated, and exercised without editing workflow JSON by hand.

## Increment 2 — monitoring, failures, and operator recovery

Deliverables:

1. A database incident ledger for stuck delivery, exhausted delivery, overdue
   review, and sanitized n8n workflow errors.
2. An n8n error-capture workflow that records metadata, never ticket bodies or
   secrets.
3. An operations-monitor workflow that periodically refreshes incidents and
   can notify an operations Slack channel after an operator attaches the
   existing Slack credential and sets its channel ID.
4. An operator status command and a documented reconciliation path for a
   failed Docs, Sheets, or engineering-Slack stage.
5. Transaction-rolled-back tests for delivery retry, duplicate callback,
   unauthorized approval, concurrency, and operational incidents.

Acceptance gate: deliberately breaking each external stage creates a visible
incident; recovery resumes only the failed stage; an operator can identify
the report, failed target, error, and safe next action in under five minutes.

## Increment 3 — privacy, retention, and tenant readiness

Deliverables:

1. A database redaction trigger removes common email address, phone number,
   and payment-card patterns before ticket text is persisted.
2. Intake workflow code redacts text before it leaves n8n for embeddings.
3. Retention policies redact expired ticket content while preserving aggregate
   cluster/audit history needed for evaluation.
4. A tenant-domain design and a default-tenant migration path. Full tenant
   isolation is a separate activation milestone: every query, uniqueness
   constraint, authorization decision, workflow configuration, and external
   credential must be tenant-scoped before onboarding a second company.

Acceptance gate: the privacy test proves raw sample PII is not stored; an
operator can run the retention job safely; no multi-customer deployment is
permitted until the tenant-isolation migration and tests are complete.

## Channel-expansion rule

New channels are adapters, not new decision engines:

```text
connector -> normalized SupportEvent -> clustering core -> ReviewRequest
          -> central authorized decision -> ordered delivery outbox
```

- Email intake must use a stable provider message ID and redact quoted history.
- Telegram approvals must validate the bot webhook and allowlist chat/user IDs.
- Email approvals must use expiring authenticated links, not reply-text parsing.
- Zendesk, Intercom, and Freshdesk connectors follow after the canonical event
  contract and tenant isolation are proven.

## Credential policy

This increment requires no new credential values. Existing placeholders remain
the only secrets: `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`,
`GOOGLE_SERVICE_ACCOUNT_JSON`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, and
`POSTGRES_PASSWORD`. n8n credentials are attached through its UI; generated
workflow files and scripts refuse secret substitution.
