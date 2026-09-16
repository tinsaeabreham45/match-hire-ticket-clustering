# Evaluation results

## Scope and method

The fixed 11-ticket input is [`../data/evaluation-tickets.json`](../data/evaluation-tickets.json). All tickets are synthetic; these are prototype results, not production-support measurements.

The final system run used source-event IDs `eval-r4-2026-09-16-TC-01` through `TC-11`, the `gemini-embedding-001` 768-dimensional embedding contract, a seed-assignment threshold of `0.85`, and n8n executions 59–72. The checkout report was human-approved through the signed Slack approval handler.

## Baseline

| Baseline | Observed result | Interpretation |
|---|---|---|
| Keyword-only, non-semantic proxy | `python3 scripts/keyword_baseline.py` completed in 0.432 ms and merged the checkout incident with the gateway outage. | Reproducible quality reference only; it is not a human-time study. |
| Human manual/proxy lead | Not independently timed in this sprint. | Do not claim time saved; collect this before a real-data pilot. |
| Final system | 11/11 expected safe behaviours observed in the final run. Checkout review draft ready in about 99 seconds; approved delivery completed in 7.4 seconds. | Demonstrates system behaviour in this small synthetic environment. |

## Final result matrix

| Case | Expected behaviour | Observed final behaviour | Pass | Evidence |
|---|---|---|---|---|
| TC-01 | Checkout cluster starts | Started checkout cluster `d262…` | Yes | `eval-r4…TC-01` |
| TC-02 | Joins checkout cluster | Joined `d262…`, similarity 0.9503 | Yes | `eval-r4…TC-02` |
| TC-03 | Review becomes eligible | Joined `d262…`, similarity 0.9362; review draft created | Yes | n8n review executions 62–63 |
| TC-04 | Joins without a second alert | Joined `d262…`, similarity 0.9460; one draft only | Yes | `eval-r4…TC-04` |
| TC-05 | Isolated OAuth cluster | Remained in the OAuth-only cluster; no cross-merge or alert | Yes | `eval-r4…TC-05` |
| TC-06 | Isolated password-reset cluster | Joined only the pre-existing password-reset cluster; no cross-merge | Yes | `eval-r4…TC-06` |
| TC-07 | Isolated expired-card cluster | Remained in the expired-card cluster; no cross-merge | Yes | `eval-r4…TC-07` |
| TC-08 | Isolated gateway-outage cluster | New cluster `ab0e…`; did not join checkout, similarity was below 0.85 | Yes | `eval-r4…TC-08` |
| TC-09 | Reject invalid text | `rejected_invalid`; no embedding or alert | Yes | `eval-r4…TC-09` |
| TC-10 | Isolated or review-needed; no unverified alert | New cluster `f2a1…`; no alert | Yes | `eval-r4…TC-10` |
| TC-11 | Empty body safely rejected | `rejected_invalid`; no embedding or alert | Yes | `eval-r4…TC-11` |

## Observed metrics

| Metric | Result |
|---|---|
| Final safe-behaviour pass rate | 11/11 test cases |
| Checkout grouping | TC-01–TC-04 in one cluster |
| Final cross-incident false merges | 0 among TC-05–TC-08 |
| Unapproved engineering alerts | 0 |
| Receipt to checkout review-ready | About 99 seconds (first receipt to draft) |
| Approval to recorded delivery | 7.4 seconds (n8n execution 72) |
| Human touches for final alert | 1 signed approval |
| Approved delivery evidence | Cluster `d262…` is `alerted`; draft `4f9…` is `delivered` with a recorded Google Doc URL |

## Failure and regression evidence

| Run | Failure | Root cause | Change | Verified result |
|---|---|---|---|---|
| Initial evaluation | TC-08 gateway outage merged with checkout at similarity 0.8469. | Threshold 0.84 was too permissive. | Raised active workflow-history threshold to 0.85; split the unsafe draft through the human gate. | Final run isolated TC-08 and TC-10 at 0.85. |
| Approval callback | n8n Code node did not expose `URLSearchParams`; an earlier raw-body access path also failed. | n8n sandbox/runtime API mismatch. | Parsed the URL-encoded Slack payload without browser APIs and read the webhook binary input correctly. | Signed approval execution 72 succeeded and created the auditable delivery. |
| Sheets delivery | Node ran in manual mapping mode with no values. | Saved mapping mode was `defineBelow`. | Set automatic input mapping and retried the failed delivery. | Execution 18 and final execution 72 completed; report status is `delivered`. |
| Model provider | OpenRouter free-model request returned an upstream overload response. | External provider availability. | Added bounded Gemini fallback with strict JSON validation. | Invalid/unavailable model output remains reviewable; no automatic alert bypasses the human gate. |

## Proxy-operator feedback

The project builder acted as the proxy operator during setup and recovery. The observed friction was n8n configuration complexity—especially credentials, active workflow versions, and Sheets mapping. In response, the repository now includes a plain-language README, click-by-click n8n setup, an operator runbook, and a dedicated release-readiness document. This is implementation feedback, not independent user research; an actual support lead should validate the workflow before a real-data pilot.
