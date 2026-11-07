#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <stage|prod>" >&2
  exit 1
fi
if [ -z "${APP_VERSION:-}" ]; then
  echo "ERROR: APP_VERSION is required (git SHA / release tag)" >&2
  exit 1
fi

cd "$(dirname "$0")"

# Load env file, auto-create from .example if missing (dev tokens only)
if [ ! -f "env/${ENV}.env" ]; then
  if [ -f "env/${ENV}.env.example" ]; then
    echo "env/${ENV}.env not found — copying from .example (dev tokens only)"
    cp "env/${ENV}.env.example" "env/${ENV}.env"
  else
    echo "ERROR: env/${ENV}.env and env/${ENV}.env.example both missing" >&2
    exit 1
  fi
fi

# Save previous version for rollback
STATE_DIR=".state"
mkdir -p "$STATE_DIR"
PREVIOUS_FILE="${STATE_DIR}/${ENV}.previous_version"
CURRENT_FILE="${STATE_DIR}/${ENV}.current_version"
if [ -f "$CURRENT_FILE" ]; then
  cp "$CURRENT_FILE" "$PREVIOUS_FILE"
  echo "Previous version recorded: $(cat "$PREVIOUS_FILE")"
fi

touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export APP_VERSION
export COMPOSE_PROJECT_NAME="payment-${ENV}"

echo "===== DEPLOY ${ENV} ====="
echo "APP_VERSION=${APP_VERSION}"
echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"

# 1. Vault first — runtime.env must be rendered before db starts (POSTGRES_PASSWORD)
echo "[1/6] Vault up"
docker compose up -d --wait vault
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV"

# 2. Data plane
echo "[2/6] db + rabbitmq up"
docker compose up -d --wait db rabbitmq

# 3. Migrations BEFORE app rollout
echo "[3/6] Applying migrations"
./migrate.sh

# 4. Pull application images (idempotent)
echo "[4/6] Pulling images"
docker compose pull api worker mock-provider

# 5. Rollout — idempotent, no 'down'
echo "[5/6] Rolling out"
docker compose up -d --remove-orphans

# 6. Record success
echo "[6/6] Recording version"
echo "$APP_VERSION" > "$CURRENT_FILE"
echo "===== DEPLOY ${ENV} OK: ${APP_VERSION} ====="