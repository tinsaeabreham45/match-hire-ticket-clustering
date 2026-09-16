# Support Ticket Root-Cause Clustering — System Plan

> **Project status (15 September 2026):** this plan was originally scoped for five days. The remaining two days are sufficient for a focused, reproducible core workflow and evidence package, not optional platform work. Synthetic Slack tickets are a proxy for unavailable customer data and a proxy support lead will perform the approval/user test. All findings must be labelled as simulated, proxy-observed, or pending rather than presented as production results.

## 0. Alignment with the job brief

The original plan covered the core architecture, AI/human decision boundary, and a test-set outline. The following gaps had to be resolved before implementation:

| Brief requirement | Gap in original plan | Resolution / acceptance condition |
|---|---|---|
| Measurable baseline and proof of improvement | Time and detection estimates were illustrative, not a reproducible method. | Time a proxy lead through a fixed 10-ticket batch, define the same task for a naive batch-prompt baseline, and record method, inputs, results, and limitations in `docs/evaluation.md`. Do not claim improvement until measurements exist. |
| Data contracts and repeatability | Ticket, cluster, report, and event schemas were not defined; duplicate Slack delivery could create duplicate tickets. | Use §5a, a unique `source_event_id`, SQL constraints, workflow version metadata, and checked-in sample configuration. |
| Evaluation pass/fail criteria | Test categories existed but each case lacked expected behavior and system-level pass rules. | Use the 10-case matrix in §7a and pass rules in §7b; preserve results for every run. |
| Operational reliability | Retry, timeout, malformed-input, LLM-JSON, and downstream-service fallbacks were unspecified. | Use the error and disposition model in §5b. No alert may bypass validation or human approval. |
| Slack approval implementation | Buttons were specified, but not their callback endpoint, signature check, replay protection, or audit trail. | Configure Slack Interactivity to an HTTPS n8n webhook; verify `SLACK_SIGNING_SECRET`, deduplicate callback payloads, and write every decision to `cluster_review_actions`. |
| Two real integrations | The plan listed integrations but did not define a verifiable v0. | v0 must persist a Slack event in Postgres/pgvector and post a review message to Slack. Docs/Sheets follow its credential feasibility check. |
| Privacy and retention | No explicit limits were defined for text sent to external model providers or stored in logs/docs. | Use synthetic data only; minimize text sent to Gemini/OpenRouter, do not put personal data in samples, and document a 30-day demo-data retention/deletion step. |

**Feasibility gate before credential entry:** confirm the actual n8n version can authenticate the selected Google Sheets and Docs nodes with the planned Google service-account credential. If not, document the supported n8n credential method and update the plan before configuring it; do not silently substitute an untracked credential or put credentials in the repo.

## 1. Problem statement
Support tickets describing the same underlying bug arrive worded differently and get triaged one-by-one. Nobody aggregates them, so engineering finds out about widespread bugs late (via manual noticing), and agents repeat the same investigation on tickets that are actually duplicates.

## 2. Target user
Support lead / support ops person at a mid-size SaaS company (50-500 employees, thousands of tickets/month) who has no dedicated support-insights analyst.

## 3. High-level flow

```
[Slack #support-tickets channel]
        |
   (Slack Trigger - n8n)
        |
        v
1. INGEST — read ticket text, timestamp, metadata
        |
        v
2. EMBED — Gemini embeddings API -> vector
        |
        v
3. COMPARE — cosine similarity vs. existing cluster seed embeddings (Postgres/pgvector)
        |
        v
4. ASSIGN-OR-CREATE — threshold rule (deterministic, no AI)
        |
        v
5. UPDATE CENTROID — recompute cluster's average vector
        |
        v
   [log row -> Google Sheet: ticket, cluster id, similarity score]
        |
        v
   IF cluster reaches the configurable verification threshold (default: 3 tickets)
        |
        v
6. VERIFY (AI judgment) — LLM (or LangGraph+LangSmith microservice) confirms
   tickets share one real root cause; can reject a false merge
        |
        v
   IF verified AND cluster crosses the configurable alert threshold (default: 3 tickets)
        |
        v
7. SYNTHESIZE DRAFT REPORT (AI judgment) — LLM writes a schema-validated bug report
        |
        v
7.5. HUMAN APPROVAL GATE — draft posted to #support-triage with Slack
     interactive buttons: [Approve & Alert Eng] / [Reject / Split Cluster]
        |
        v
   IF approved:
        |
        v
8. OUTPUT — Google Doc created with full report
        |
        v
9. NOTIFY — Slack message to #eng-alerts linking to the doc
   (IF rejected: cluster flagged "needs review" in Google Sheet, no eng alert sent)
```

**Cluster assignment logic (revised — see Upgrade B rationale below):** instead of comparing each new ticket only to a centroid that shifts every time a ticket joins, assignment is checked against the **cluster's seed ticket embedding** (the first ticket that started the cluster), not a drifting average. This prevents "centroid drift," where a chain of borderline-similar tickets slowly pulls a cluster away from its original meaning until it contains unrelated issues. A running centroid is still stored for reporting/display purposes, but is NOT what gates new tickets joining.

**Alert lifecycle:** a cluster is eligible once when it first reaches the alert threshold and has a `verified` result. Create a review record with status `pending`; it cannot produce an engineering alert until a human approves it. `rejected`, `split`, invalid LLM output, and low-confidence verification results are retained as reviewable outcomes. An approved cluster cannot alert again unless a human explicitly reopens it.

## 4. Tools / integrations (all free-tier or free self-hosted)

| Purpose | Tool | Real or simulated |
|---|---|---|
| Ticket intake | Slack (#support-tickets channel, Slack Trigger node) | Real (channel + trigger real; tickets arrive via simulator bot below) |
| Ticket simulator | Custom bot/script that posts synthetic tickets into #support-tickets on an interval, mimicking real arrival timing | Simulated data source, real delivery mechanism |
| Embeddings | Google Gemini Embedding API (placeholder: GEMINI_API_KEY; `gemini-embedding-001`, `CLUSTERING`, 768 dimensions for this sprint) | Real |
| Vector storage / cluster state | Postgres + pgvector (same box as n8n) | Real |
| Root-cause verification | LLM call via OpenRouter (placeholder: OPENROUTER_API_KEY, model TBD) | Real |
| Report synthesis | LLM call via OpenRouter (same key, may use a different model than verification) | Real |
| Report doc | Google Docs (n8n node) | Real |
| Dashboard / eval log | Google Sheets (n8n node) | Real |
| Alerting | Slack (#eng-alerts channel, webhook or Slack node) | Real |
| Human approval gate | Slack (#support-triage channel, interactive Approve/Reject buttons) | Real |
| Orchestration engine | n8n, self-hosted | Real |
| Hosting | AWS EC2 t3.small + Docker Compose + Caddy (HTTPS) | Real |

Note: since there's no live company data, tickets are synthetic — generated and posted into the Slack channel by a small ticket-simulator bot to mimic real-time arrival, rather than pasted in manually. This is the one "simulated" piece; state this assumption explicitly in the case study.

**Embedding contract:** all vectors use `gemini-embedding-001` with task type `CLUSTERING` and `output_dimensionality: 768`. A model or dimension change requires a fresh collection and re-embedding; vectors from different embedding spaces must never be compared. This fixed dimension allows a `vector(768)` pgvector index and a reproducible threshold evaluation.

## 4a. Infrastructure status
- [DONE] EC2 instance launched (t3.small, Ubuntu), Elastic IP allocated (16.170.93.79), nip.io hostname in use (16.170.93.79.nip.io) — no domain purchase needed
- [DONE] Docker + Docker Compose installed on the instance
- [DONE] docker-compose.yml running: postgres (pgvector), n8n, caddy (auto-HTTPS via nip.io) — all three containers healthy
- [DONE] n8n reachable at https://16.170.93.79.nip.io, owner account created
- [NEXT] Add credentials inside n8n's credential store (see placeholder list below) — never in code/repo
- [NEXT] Build the workflow nodes against this live instance

## 4b. Credentials — placeholder names only (real values live ONLY in n8n's credential store or a local untracked .env, never in the repo or this doc)

| Placeholder name | Used for | Where it's entered |
|---|---|---|
| `SLACK_BOT_TOKEN` | Slack Bot OAuth Token (xoxb-...) | n8n Slack credential |
| `SLACK_SIGNING_SECRET` | Verifies Slack interactive button payloads | n8n Slack credential / webhook verification |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Sheets + Docs API auth | n8n Google credential (paste JSON key) |
| `GEMINI_API_KEY` | Embeddings | n8n HTTP/Gemini credential |
| `OPENROUTER_API_KEY` | Verification + report synthesis LLM calls | n8n HTTP Header Auth credential |
| `POSTGRES_PASSWORD` | Already set during infra setup — do not change without updating both services | docker-compose.yml environment (server-side only, not repo) |

**Security note:** if any real secret value is ever accidentally pasted into a chat, doc, or committed to git, rotate it immediately rather than assuming it's fine — regenerating a Slack token or API key takes seconds and removes all risk.

## 5. What's AI judgment vs. what's a deterministic rule vs. human-retained
- Deterministic (no LLM): ingest, embed, similarity comparison vs. seed embedding, threshold assign/create, centroid update (display only), logging, notification delivery
- AI judgment (LLM): root-cause verification (step 6), report synthesis (step 7)
- Human-retained: final approval before any alert reaches engineering (step 7.5) — the AI drafts and verifies, but a person decides whether it actually goes out. This is the concrete answer to the brief's explicit grading line "human approval points, fallbacks, privacy, and permission boundaries."

This three-way split (rule / AI / human) is a stronger answer than a simple AI-vs-human split for "work delegated to AI and judgment retained by humans" in the case study.

## 5a. Data contracts and minimum database state

All timestamps are ISO-8601 UTC. `source_event_id` is the Slack event ID or simulator UUID and is unique, making delivery idempotent.

| Object | Required fields | Validation / use |
|---|---|---|
| Ticket | `ticket_id`, `source_event_id`, `text`, `received_at`, `source`, `embedding_model`, `embedding` | Reject empty/whitespace text before embedding; persist a safe error disposition for malformed input. |
| Cluster | `cluster_id`, `seed_ticket_id`, `seed_embedding`, `centroid_embedding`, `ticket_count`, `assignment_threshold`, `status`, `alerted_at` | Assignment compares only with `seed_embedding`; centroid is a display statistic. |
| Verification | `cluster_id`, `model`, `verdict`, `confidence`, `root_cause`, `evidence_ticket_ids`, `raw_response_ref` | Accept only schema-valid JSON and a `verified` verdict at or above the configured confidence threshold. |
| Review action | `action_id`, `cluster_id`, `action`, `actor_id`, `acted_at`, `callback_id`, `notes` | `callback_id` is unique; record approve, reject, split, and reopen actions. |
| Report draft | `cluster_id`, `summary`, `suspected_root_cause`, `impact`, `evidence`, `recommended_next_step`, `status` | Draft is not an engineering alert and cannot be published until approval. |

Implement these as `tickets`, `clusters`, `cluster_tickets`, `cluster_verifications`, `cluster_review_actions`, and `workflow_runs` tables. The repository migration is the source of truth; Google Sheets is a human-readable operational log, not cluster state.

## 5b. Reliability, validation, and disposition rules

- Slack event receipt: acknowledge promptly, ignore or record unsupported event types, and prevent processing the same `source_event_id` twice.
- External calls: use bounded retries for transient HTTP/429/5xx failures, with a timeout and a captured error record. Do not retry invalid credentials, 4xx validation errors, or schema-invalid LLM output indefinitely.
- Embedding failure: mark the ticket `embedding_failed`, retain it for reprocessing, and do not assign a cluster.
- Database failure: do not claim success to the downstream flow; record an n8n execution error and route to an operator-visible error channel/log.
- Verification or report failure: set the cluster to `needs_review`; do not notify `#eng-alerts`.
- Slack approval callback: validate signature and timestamp, reject replayed callbacks, and resolve the action against the current pending review state.
- Sheets/Docs failure after approval: retain the approved report payload and notify the operator that document delivery is pending; do not silently drop it.

## 6. Key design decisions to defend (Day 2 architecture doc)
- Similarity threshold value (e.g. 0.82-0.85) — justify against test cases, show what breaks at 0.80 vs 0.90
- Minimum cluster size before something counts as a "cluster" vs. noise (e.g. 2)
- Why assignment is checked against the cluster's seed embedding, not a shifting centroid average — prevents "centroid drift" (a chain of borderline-similar tickets slowly pulling a cluster away from its original meaning). Verification (step 6) is a second, independent guardrail against the same failure mode — even if drift slipped through the seed-anchor check, the LLM reviewing the whole cluster's ticket text catches it before anything gets synthesized.
- Why there's a human approval gate (step 7.5) before engineering gets alerted — false alarms in an eng channel destroy trust fast; the AI drafts and verifies, a person decides whether it ships
- Why Slack + Sheets + Docs instead of a custom web UI (speed, real tools people already use, no separate hosting)

## 7. Evaluation design

### 7a. Fixed 10-case test set

| Case | Scenario | Expected behavior |
|---|---|---|
| 1–4 | Four differently worded reports of a mobile-Safari checkout 500 | One cluster; after the third ticket it is verified, receives a pending review draft, and requires approval before any engineering alert. |
| 5 | OAuth 401 login issue | Separate cluster; never merges with password-reset delivery or checkout. |
| 6 | Password-reset email not delivered | Separate cluster; never merges with OAuth 401 or checkout. |
| 7 | Payment failed because the card expired | Separate cluster; never merges with a gateway outage merely because both mention payment failure. |
| 8 | Payment failed because of a gateway outage | Separate cluster; never merges with expired-card reports. |
| 9 | One-word ticket: `broken` | Validated as insufficient detail; no embedding/alert; disposition is logged for review. |
| 10 | One non-English ticket | Process it or route it to `needs_review` according to supported embedding behavior; it may not cause an unverified alert. |
| 11 | Empty-body ticket | Reject safely, log the disposition, and never embed, cluster, or alert. |

### 7b. Metrics and pass rules

- **Cluster correctness:** all cases 1–4 are together; cases 5–8 do not false-merge; malformed inputs do not join a cluster. Pass: 100% on the fixed 11-case set before handoff.
- **Alert safety:** 0 engineering alerts without a schema-valid verification and recorded human approval. Pass: 100% of executions.
- **Latency:** record receipt-to-review-ready latency per valid ticket and report median/p95. Target: under three minutes in the demo environment; mark a miss as a failure rather than changing the target after the fact.
- **Manual effort:** time a proxy user completing the fixed batch manually and in the naive batch-prompt baseline, using the same starting inputs and a timer. Compare against review time in the final system; report sample size and limitations.
- **Reliability:** record retries, error dispositions, invalid-model-output handling, and approved-document delivery. Pass: each induced failure follows §5b and creates no silent loss or unapproved alert.

### 7c. Two-day recovery plan

**Day 1 (core and v0):** finalize credentials in n8n using only §4b placeholders; apply schema; create Slack→Postgres→cluster→Slack-review core; run the simulator in dry-run and live modes; verify one end-to-end happy path and the two required integrations.

**Day 2 (hardening and handoff):** add verification/report generation, approval callback, Docs/Sheets delivery, retry/error paths, and all fixed tests; measure proxy baselines; complete runbook, results, case study, and demo checklist. Optional LangGraph work and any custom dashboard remain out of scope unless every acceptance condition is complete.

## 8. Explicit scope cuts (non-goals)
- No live company/customer data — synthetic tickets only
- No LangGraph rebuild of the whole system — at most a small verification microservice, only if time allows after Day 4
- No custom web dashboard — Google Sheets/Docs stand in for the UI
- No multi-tenant/config UI — single hardcoded Slack workspace/channel for this sprint
