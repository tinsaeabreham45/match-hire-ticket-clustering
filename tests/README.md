# Production-hardening checks

These checks run only against the hardening branch. They do not call Slack,
Google, OpenRouter, or Gemini.

```bash
node tests/test_delivery_workflow.mjs
node scripts/validate-production-foundation.mjs
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_review_integrity.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_outbox_state_machine.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_operational_observability.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_privacy_retention.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_recurrence_episodes.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_pilot_readiness_gates.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_incident_lifecycle.sql
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/test_investigation_cards.sql
bash tests/test_ingestion_concurrency.sh
```

Use an isolated test database for the SQL check after applying migrations in
numeric order. `TEST_DATABASE_URL` is intentionally not included in this
repository and must never point to the live database.

Before a live rollout, additionally run controlled tests for concurrent ticket
ingestion, a non-approver callback, a stale callback, a duplicate callback,
and each failed delivery stage. Record the execution IDs in the change record.
