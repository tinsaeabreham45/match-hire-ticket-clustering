# Production-hardening checks

These checks run only against the hardening branch. They do not call Slack,
Google, OpenRouter, or Gemini.

```bash
node tests/test_delivery_workflow.mjs
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_review_integrity.sql
```

Use an isolated test database for the SQL check after applying migrations in
numeric order. `TEST_DATABASE_URL` is intentionally not included in this
repository and must never point to the live database.

Before a live rollout, additionally run controlled tests for concurrent ticket
ingestion, a non-approver callback, a stale callback, a duplicate callback,
and each failed delivery stage. Record the execution IDs in the change record.
