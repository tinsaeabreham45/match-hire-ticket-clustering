# Evaluation worksheet

Status: **measurement pending**. This document is a protocol and result log; blank fields are not claims of success.

## Fixed inputs

Use [`../data/evaluation-tickets.json`](../data/evaluation-tickets.json) unchanged for every comparison. It contains 11 tickets: four reports of one checkout incident, four distinct-but-related issues, a too-short ticket, a non-English ticket, and an empty ticket.

The empty ticket cannot be posted through Slack because Slack rejects it. Exercise it through the n8n webhook/manual execution path using the same `source_event_id`, and record its `rejected_invalid` database disposition.

## Baseline protocol

| Baseline | Same task | Measure | Result |
|---|---|---|---|
| Manual/proxy lead | Given the fixed 11 tickets in arrival order, identify recurring incidents and write which should go to engineering. | Timer start→finished incident list; correct grouping; false alerts. | Pending |
| Naive batch prompt | Paste the same 11 tickets into one recorded generic ChatGPT/LLM prompt and request groups plus alerts. Preserve the prompt/model/date. | Timer, correct grouping, false alerts, ungrounded claims. | Pending |
| System | Post the valid simulator cases in the fixed order, trigger the empty case directly, and approve only a schema-valid checkout report. | Receipt→review-ready latency, correct grouping, retries/errors, human touches, unapproved alerts. | Pending |

Use one proxy user consistently where possible. Record their role, familiarity with the test, and whether they saw the expected outcomes in advance. This is a small synthetic evaluation, not a statistically generalizable user study.

## Result matrix

| Case | Expected behavior | Observed disposition / cluster | Pass? | Evidence (execution URL, row, or screenshot) |
|---|---|---|---|---|
| TC-01 | Checkout cluster starts | Pending | Pending | |
| TC-02 | Joins checkout cluster | Pending | Pending | |
| TC-03 | Joins; verification/review becomes eligible | Pending | Pending | |
| TC-04 | Joins; no second engineering alert | Pending | Pending | |
| TC-05 | Isolated OAuth cluster | Pending | Pending | |
| TC-06 | Isolated password-reset cluster | Pending | Pending | |
| TC-07 | Isolated expired-card cluster | Pending | Pending | |
| TC-08 | Isolated gateway-outage cluster | Pending | Pending | |
| TC-09 | `rejected_invalid`; no embedding or alert | Pending | Pending | |
| TC-10 | Isolated or needs-review; never unverified alert | Pending | Pending | |
| TC-11 | Empty body safely rejected | Pending | Pending | |

## Summary metrics

| Metric | Target / rule | Result |
|---|---|---|
| Correct checkout grouping | TC-01–04 in one cluster | Pending |
| False merges | 0 across TC-05–08 | Pending |
| Unsafe alerts | 0 without valid verification and recorded approval | Pending |
| Median / p95 receipt→review-ready latency | Under 3 minutes in the demo environment | Pending |
| Manual baseline time | Measured, not estimated | Pending |
| Naive batch-prompt time | Measured, prompt preserved | Pending |
| System review time / human touches | Measured | Pending |
| Retry/error dispositions | Every induced failure visible and safe | Pending |

## Failure and regression log

| Date/run | Failure case | Root cause | Change made | Before | After | Owner |
|---|---|---|---|---|---|---|
| Pending | Seed/centroid drift test | Pending | Pending | Pending | Pending | |
| Pending | Invalid LLM JSON | Pending | Pending | Pending | Pending | |
| Pending | Slack callback replay/signature failure | Pending | Pending | Pending | Pending | |

## Proxy-user feedback

- User/proxy and context: Pending
- What they tried: Pending
- Feedback: Pending
- Change made in response: Pending
- Remaining request / limitation: Pending
