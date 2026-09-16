# Submission package

## What to send

1. GitHub repository link (private access is acceptable under the brief).
2. Five-minute screen recording link.
3. Live operator URL: `https://16.170.93.79.nip.io` and reviewer access instructions if access is granted.
4. The case study: [`case-study.md`](case-study.md).
5. The observed synthetic evaluation: [`evaluation.md`](evaluation.md).

## Five-minute recording outline

1. **0:00–0:35 — problem:** support leads see repeated tickets too late; state that all demo data is synthetic.
2. **0:35–1:20 — architecture:** Slack → n8n → Gemini/pgvector → verification → human review → Docs/Sheets/engineering.
3. **1:20–3:10 — core demo:** show TC-01–TC-04 clustering, the review card, and the approved report delivery.
4. **3:10–4:05 — safety:** show rejected malformed ticket, the human split action, and the 0.85 threshold regression fix.
5. **4:05–5:00 — evidence and limits:** open `evaluation.md`; state 11/11 final synthetic safe behaviours, no human-time claim, and the two-week plan.

## Submission note

> I built a support-ticket root-cause clustering workflow for a support lead. It groups recurring synthetic Slack tickets using seed-anchored pgvector similarity, verifies a shared root cause with schema-constrained LLM output, and requires a human approval before notifying engineering. The repository includes runnable n8n templates, SQL, sample configuration without secrets, a nontechnical setup guide, runbook, evaluation evidence, and case study. The demo uses synthetic data because company data was unavailable; all reported results are explicitly labelled synthetic/proxy.
