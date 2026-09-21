# Support Ticket Root-Cause Clustering

An event-driven support-ops prototype that groups recurring synthetic Slack tickets, verifies likely root causes with an LLM, and requires a support lead’s approval before engineering is alerted.

This is a job-application sprint artifact. It uses synthetic data as a proxy for a mid-size SaaS support team; it must not be represented as production performance or customer-data processing.

## What it does

1. Receives a Slack ticket event and validates/idempotently records it.
2. Embeds the text, assigns it against seed embeddings in pgvector, and retains a display centroid.
3. When a cluster reaches three tickets, verifies the shared root cause, drafts a report, and posts it to `#support-triage` for a human decision.
4. Only an approved review can create a Google Doc and notify `#eng-alerts`.

The architecture, safety gates, evaluation approach, and operator handoff are documented in this README and the public-facing files under `docs/`.

## Three-step setup

1. On an isolated staging database in the EC2 Postgres/pgvector service, run `scripts/apply-migrations.sh DATABASE_NAME`. It applies the ordered migrations under `docs/sql/`; promote them to the live database only after the staging checks pass.
2. In n8n, import the workflow templates from `workflows/`, attach the required credentials, set channel/model/Google identifiers and the review sub-workflow ID, then activate only after the dry-run checks in the runbook pass.
3. Copy `.env.example` to an untracked `.env`; run `python3 scripts/ticket_simulator.py --dry-run` first, then run it with `--post` after setting the Slack token and support-channel ID.

## Repository map

- `workflows/` — n8n import templates and node configuration notes.
- `scripts/` — dependency-free synthetic-ticket simulator.
- `data/` — fixed 11-case evaluation input.
- `docs/` — operator runbook, evaluation worksheet, case study, release readiness notes, and SQL schema.

The production-ready feature branches add an outbox-backed delivery worker,
authorized-reviewer checks, serialized ingestion, operational incident capture,
privacy/retention controls, linked recurrence episodes, and staging/deployment tooling. Start with
[`docs/production-foundation-plan.md`](docs/production-foundation-plan.md),
then use [`docs/deployment-guide.md`](docs/deployment-guide.md).

## Run it without technical background

There are two safe ways to use this project.

### Option A — see the simulator locally (no account or secret required)

This shows the exact synthetic support tickets that would be sent. It changes nothing in Slack, n8n, Google, or Postgres.

1. Download this repository as a ZIP and unzip it.
2. Open **Terminal** on macOS or **PowerShell** on Windows.
3. Move into the unzipped project folder. For example: `cd ~/Downloads/match-hire-ticket-clustering`.
4. Run: `python3 scripts/ticket_simulator.py --dry-run`.
5. You should see ticket cases `TC-01` through `TC-11` printed on screen. This confirms the sample-ticket component works.
6. Optionally run `python3 scripts/keyword_baseline.py` to reproduce the deliberately simple, non-semantic quality baseline used in the evaluation.

### Option B — operate the live demo

The live workflow editor is [https://16.170.93.79.nip.io](https://16.170.93.79.nip.io). It is an **operator console**, not a public demo: it requires an authorised n8n account, access to the project Slack workspace, and configured credentials. A support lead uses it as follows:

1. Sign in to n8n at the link above.
2. Open **Executions** to see incoming support-ticket runs and any errors.
3. Send the test tickets to the project’s Slack support channel using the simulator or the agreed manual test messages.
4. When a Slack card says **Root-cause review required**, read the evidence and choose **Approve**, **Reject**, or **Split cluster**.
5. Confirm an approved item appears in the Google Sheet and its Google Doc link is recorded. The full click-by-click setup and recovery steps are in [`docs/n8n-ui-setup.md`](docs/n8n-ui-setup.md) and [`docs/operator-runbook.md`](docs/operator-runbook.md).

There is not yet a public, anonymous “anyone can run it” URL. That would require a separate, access-controlled web interface or a Slack workspace invitation flow; exposing the n8n editor or the approval endpoint as a public application would not be safe.

## Safety boundary

- Never commit `.env`, key/certificate files, service-account JSON, tokens, or database passwords.
- `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`, `GOOGLE_SERVICE_ACCOUNT_JSON`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, and `POSTGRES_PASSWORD` are placeholder names only.
- The imported n8n workflow is a template. It does not include credentials and should be configured and tested in the live instance by the operator.

## Evidence status

The final fixed synthetic evaluation is recorded in [`docs/evaluation.md`](docs/evaluation.md): 11/11 expected safe behaviours were observed, including one approved end-to-end delivery. It includes failure/regression evidence and clearly states the remaining limitation: no independent human-time baseline or real-customer-data claim.

## Release readiness

[`docs/release-readiness.md`](docs/release-readiness.md) records the implemented security controls, the honest scale limits of this single-instance synthetic-data demo, and the production hardening path.
