#!/usr/bin/env bash
set -euo pipefail

database_name="${1:?Usage: scripts/apply-migrations.sh DATABASE_NAME}"
if [[ ! "$database_name" =~ ^[a-z][a-z0-9_]{2,62}$ ]]; then
  echo "Database name must use lowercase letters, numbers, and underscores." >&2
  exit 2
fi

for migration in docs/sql/[0-9][0-9][0-9]_*.sql; do
  echo "Applying $migration to $database_name"
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d "$database_name" < "$migration"
done
