#!/usr/bin/env bash
set -euo pipefail

database_name="${1:-n8n_staging}"
if [[ ! "$database_name" =~ ^[a-z][a-z0-9_]{2,62}$ ]]; then
  echo "Database name must use lowercase letters, numbers, and underscores." >&2
  exit 2
fi

if docker compose exec -T postgres psql -U n8n -d n8n -Atqc "SELECT 1 FROM pg_database WHERE datname = '$database_name'" | grep -qx 1; then
  echo "Refusing to overwrite existing database: $database_name" >&2
  exit 1
fi

docker compose exec -T postgres createdb -U n8n "$database_name"
echo "Created isolated staging database: $database_name"
