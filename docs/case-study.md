# Case study — support-ticket root-cause clustering

## Outcome

I built a support-ops workflow for a lead at a 50–500-person SaaS company: it turns recurring synthetic Slack tickets into evidence-backed root-cause clusters, requires human approval, and only then alerts engineering. In the final fixed 11-case synthetic run, all 11 expected safe behaviours were observed; the checkout report became review-ready in about 99 seconds and its approved delivery completed in 7.4 seconds.

These are synthetic/proxy results, not claims about a production support team or real customer data.

## User, problem, and scope

The target user is a support lead without a dedicated support-insights analyst. Their recurring problem is noticing a real incident only after several differently worded tickets have already caused repeated investigation.

The prototype does not ingest real customer data, offer a multi-tenant service, replace a ticketing platform, or auto-alert engineering. It uses a fixed synthetic test set because company data was unavailable.

## Workflow changed

| Stage | Before | After |
|---|---|---|
| Trigger | Agents notice individual Slack tickets | Signed Slack event creates an idempotent intake record |
| Grouping | Lead manually spots patterns later | Gemini embedding compared to a fixed pgvector seed anchor |
| Judgment | Informal manual triage | Strict structured LLM verification plus confidence threshold |
| Approval | Alert quality varies by person/time | Support lead approves, rejects, or splits a Slack review card |
| Output | Duplicate investigation and delayed escalation | Auditable cluster, Google Doc report, Sheet log, engineering alert |

## System design and trade-offs

Slack provides the interface; n8n orchestrates; Postgres/pgvector stores durable state; Gemini supplies embeddings and a fallback model path; OpenRouter is the primary verification/report provider; Google Docs and Sheets provide a lightweight operator record.

Assignment uses a cluster’s first-ticket seed embedding, not its moving centroid. That prevents a series of borderline tickets from slowly changing the definition of a cluster. The centroid is retained as a display statistic only. A deterministic threshold routes candidates, LLM output must satisfy a strict schema, and a human retains final alert authority.

## Evaluation, failures, and changes

The full result table is in [`evaluation.md`](evaluation.md). The final pass grouped TC-01–TC-04 together, isolated gateway-outage TC-08 and non-English TC-10, rejected the malformed cases, and produced one approved checkout report.

The most useful failure was a gateway-outage ticket that initially merged with checkout at 0.8469 similarity under a 0.84 threshold. The support gate split that draft, and I calibrated the active workflow to 0.85. The final run kept the clear checkout reports (0.9362–0.9503) together and isolated the 0.8469 gateway case. Other observed fixes covered an OpenRouter overload fallback, n8n’s callback-code runtime differences, and Sheets automatic mapping.

The keyword-only baseline also merged checkout and gateway. It is a reproducible quality reference, not a human-time benchmark; no time-saved claim is made.

## AI collaboration and human judgment

AI is used for embedding, root-cause verification, and report drafting. Deterministic database code owns idempotency, assignment, thresholds, audit records, and delivery state. The human reviewer decides whether the evidence justifies an engineering alert and can reject or split unsafe clusters.

Implementation assistance was used to draft workflow/configuration artifacts and diagnose errors. Generated workflow code was verified through local JSON/Code-node checks and live execution evidence. The core decisions personally owned by the project builder were the problem scope, synthetic-data boundary, threshold calibration, human approval gate, and the decision not to claim production results.

## Limits and next two weeks

This is a single-instance synthetic demo. It needs a real support-lead study, human baseline timing, access controls/retention settings, delivery-outbox hardening, and queue-based n8n workers before production use.

1. Shadow-run against consented, minimized real data with a support lead and measure manual baseline time/quality.
2. Add labelled incidents, calibrate thresholds per product area, and monitor false merges/review load.
3. Add queue workers, delivery retries/outbox, metrics, backups, and an issue-tracker integration only after operator trust is established.
