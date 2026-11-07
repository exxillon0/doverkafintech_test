#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-../migrations}"
ADVISORY_LOCK_ID=728394

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "ERROR: migrations dir not found: $MIGRATIONS_DIR" >&2
  exit 1
fi

# Ensure tracking table exists
docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U payments -d payments <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

# Collect pending migrations
PENDING=()
for f in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
  version=$(basename "$f")
  applied=$(docker compose exec -T db psql -tA -U payments -d payments \
    -c "SELECT 1 FROM schema_migrations WHERE version = '${version}'" | tr -d '[:space:]')
  if [ "$applied" = "1" ]; then
    echo "SKIP  ${version} (already applied)"
  else
    echo "QUEUE ${version}"
    PENDING+=("$f")
  fi
done

if [ ${#PENDING[@]} -eq 0 ]; then
  echo "No migrations to apply."
  exit 0
fi

echo "Applying ${#PENDING[@]} migration(s) under advisory lock ${ADVISORY_LOCK_ID} ..."

{
  echo "BEGIN;"
  echo "SELECT pg_advisory_lock(${ADVISORY_LOCK_ID});"
  for f in "${PENDING[@]}"; do
    version=$(basename "$f")
    echo "-- ===== ${version} ====="
    cat "$f"
    echo "INSERT INTO schema_migrations(version) VALUES ('${version}');"
  done
  echo "SELECT pg_advisory_unlock(${ADVISORY_LOCK_ID});"
  echo "COMMIT;"
} | docker compose exec -T db psql -v ON_ERROR_STOP=1 -U payments -d payments

echo "Migrations applied."