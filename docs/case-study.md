# Case study scaffold — Support ticket root-cause clustering

## Headline

Pending: one sentence that states the target user, recurring workflow changed, and measured result. Do not insert a result until `evaluation.md` contains evidence.

## User, problem, and scope

- Target user: Support lead / support-ops practitioner at a 50–500-person SaaS company without a dedicated support-insights analyst.
- Job to be done: Detect recurring underlying bugs from differently worded tickets early enough to give engineering one evidence-backed alert.
- Existing workflow: Tickets arrive in Slack; agents triage one-by-one; a lead manually notices patterns later; duplicate investigations and late incident discovery follow.
- Evidence and assumption: Customer data was unavailable, so 11 synthetic tickets and a proxy user are used. Label all resulting evidence as synthetic/proxy.
- Non-goals: no real customer data, multi-tenant product, custom dashboard, or LangGraph rebuild.

## Workflow map

| Stage | Before | After |
|---|---|---|
| Trigger | New support ticket | Slack ticket event |
| Input | Free-text ticket, agent context | Validated text, source event ID, timestamp |
| Judgment | Each agent and later the support lead | Deterministic seed-anchor grouping; LLM verification; human final approval |
| Tools | Slack and manual investigation | Slack, n8n, Gemini, Postgres/pgvector, OpenRouter, Google Docs/Sheets |
| Output | Repeated investigations / late discovery | Auditable cluster, review draft, approved engineering alert |
| Exceptions | Usually manual and inconsistent | Invalid input, provider errors, low confidence, and rejected/split clusters enter reviewable states |

## System and trade-offs

Describe the event flow from the system plan. Explain why assignment uses a cluster's seed embedding rather than a drifting centroid; why the centroid remains display-only; why Slack/Sheets/Docs were chosen over a custom UI; and why an alert needs human approval.

## Delegation and judgment

- Deterministic system work: validation, idempotency, embeddings, seed-anchor comparison, centroid recomputation, audit logging, delivery.
- AI work: root-cause verification and structured report drafting.
- Human work: deciding whether evidence is sufficient to alert engineering, and rejecting/splitting/reopening a cluster.
- AI collaboration note: list the tools used, what work was delegated, how output was verified, what was rejected/corrected, and the decisions personally owned.

## Evaluation and results

Link the fixed test set and baseline protocol. Insert measured grouping accuracy, false-merge count, latency, manual-touch comparison, and failure/regression results only after they are recorded. Explain the sample size and proxy-data limitation.

## Two-week next iteration plan

1. Shadow-run against a consented, minimized real-data source with a support lead; compare clusters without auto-alerting.
2. Calibrate thresholds per product area and add a labelled evaluation set from reviewed incidents.
3. Add issue-tracker integration only after alert precision and operator trust meet the documented acceptance criteria.
