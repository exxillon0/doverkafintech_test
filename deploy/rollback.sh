#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <stage|prod>" >&2
  exit 1
fi

cd "$(dirname "$0")"

if [ ! -f "env/${ENV}.env" ]; then
  echo "ERROR: env/${ENV}.env not found" >&2
  exit 1
fi

STATE_DIR=".state"
PREVIOUS_FILE="${STATE_DIR}/${ENV}.previous_version"
CURRENT_FILE="${STATE_DIR}/${ENV}.current_version"

if [ ! -f "$PREVIOUS_FILE" ]; then
  echo "ERROR: no previous version recorded for ${ENV} — cannot rollback automatically." >&2
  echo "       Deploy a known-good version manually: make deploy ENV=${ENV} APP_VERSION=<sha>" >&2
  exit 1
fi

PREVIOUS=$(cat "$PREVIOUS_FILE")
echo "===== ROLLBACK ${ENV} → ${PREVIOUS} ====="

touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export APP_VERSION="$PREVIOUS"
export COMPOSE_PROJECT_NAME="payment-${ENV}"

docker compose pull api worker mock-provider
docker compose up -d --remove-orphans

echo "$PREVIOUS" > "$CURRENT_FILE"
rm -f "$PREVIOUS_FILE"

echo "===== ROLLBACK OK: ${ENV} = ${PREVIOUS} ====="
echo "NOTE: database schema was NOT rolled back. See RUNBOOK.md § 'Откат'."