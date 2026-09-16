# AI Collaboration Note

## Role of AI in this project

An AI coding assistant was used as an implementation and debugging collaborator during this five-day sprint. It helped draft workflow JSON, SQL, Python utilities, documentation structure, and operator instructions. Generative AI is also part of the product itself: Gemini creates embeddings and provides a fallback path for structured verification/report generation; OpenRouter is the primary structured-output provider.

## Work delegated to AI

- Drafting the n8n workflow templates and their structured-output validation logic.
- Drafting the pgvector schema, parameterized database functions, indexes, and audit-state design.
- Producing the synthetic-ticket simulator, reproducible keyword-only baseline, and documentation scaffolds.
- Diagnosing live integration failures from n8n execution evidence and proposing scoped fixes.
- Improving nontechnical setup instructions, the runbook, evaluation package, and case-study narrative.

## How AI-generated work was verified

- Every workflow export was parsed as JSON and every n8n Code node was syntax-checked locally.
- The simulator and keyword baseline were executed locally.
- SQL functions were applied to the live Postgres instance and smoke-tested.
- The final fixed TC-01–TC-11 synthetic suite was sent through the signed Slack event path and checked against Postgres records and n8n executions.
- The final approved checkout cluster was verified as `alerted`; its report draft was verified as `delivered` with an auditable Slack approval and recorded Google Doc URL.
- No credentials or private keys were added to the repository; templates retain placeholders only.

## Important corrections and rejected outputs

1. The initial seed-assignment threshold of 0.84 merged a payment-gateway outage into the checkout incident at 0.8469 similarity. The unsafe draft was split by the human-review path; the active workflow was calibrated to 0.85 and the final regression run kept the cases separate.
2. An OpenRouter free-model overload was not treated as a successful verification. A bounded Gemini fallback with strict JSON validation was added; provider failure routes to a reviewable state, never directly to engineering.
3. Initial Slack callback code relied on browser/runtime APIs unavailable in n8n. It was replaced with raw-body-safe, URL-encoded parsing and signature validation compatible with the installed runtime.
4. A Google Sheets node was saved in manual mapping mode without values. It was corrected to automatic input mapping and the delivery was retried successfully.

## Decisions personally owned by the project builder

- Choosing support-lead incident detection as the user problem and constraining the project to synthetic data.
- Preserving the decision boundary: deterministic seed-anchor assignment, model-assisted verification, and mandatory human approval before engineering notification.
- Setting the evaluation criteria, choosing to document the false merge rather than hide it, and accepting the 0.85 calibrated threshold only after a regression run.
- Refusing to claim production performance, real-customer-data results, or a human time-saved result without corresponding evidence.
- Prioritizing an operational handoff: README, runbook, recovery guidance, evaluation evidence, security/scalability limits, and a two-week follow-up plan.
