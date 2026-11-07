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

# --- env file: auto-create from .example if missing (dev/demo convenience) ---
if [ ! -f "env/${ENV}.env" ]; then
  if [ -f "env/${ENV}.env.example" ]; then
    echo "env/${ENV}.env not found — copying from .example (dev tokens only)"
    cp "env/${ENV}.env.example" "env/${ENV}.env"
  else
    echo "ERROR: env/${ENV}.env and env/${ENV}.env.example both missing" >&2
    exit 1
  fi
fi

# --- state dir for previous/current version ---
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

# --- VAULT_DEV_ROOT_TOKEN: self-heal for dev-mode Vault ---
# If token is empty/missing (e.g. CI secret not set, or empty .env), generate
# a random one and persist it to env/${ENV}.env. For ENV=prod it requires
# explicit ALLOW_DEV_VAULT=1 to prevent accidental "prod" with a dev token.
if [ -z "${VAULT_DEV_ROOT_TOKEN:-}" ]; then
  if [ "$ENV" = "prod" ] && [ "${ALLOW_DEV_VAULT:-0}" != "1" ]; then
    echo "ERROR: ENV=prod requires VAULT_DEV_ROOT_TOKEN." >&2
    echo "       Set it in deploy/env/prod.env or export ALLOW_DEV_VAULT=1" >&2
    echo "       to auto-generate a dev-mode token (fine for local demos)." >&2
    exit 1
  fi
  VAULT_DEV_ROOT_TOKEN="$(openssl rand -hex 24)"
  export VAULT_DEV_ROOT_TOKEN
  if grep -q '^VAULT_DEV_ROOT_TOKEN=' "env/${ENV}.env" 2>/dev/null; then
    sed -i.bak "s|^VAULT_DEV_ROOT_TOKEN=.*|VAULT_DEV_ROOT_TOKEN=${VAULT_DEV_ROOT_TOKEN}|" "env/${ENV}.env"
  else
    echo "VAULT_DEV_ROOT_TOKEN=${VAULT_DEV_ROOT_TOKEN}" >> "env/${ENV}.env"
  fi
  rm -f "env/${ENV}.env.bak"
  echo "NOTE: VAULT_DEV_ROOT_TOKEN was empty — generated dev-mode token, saved to env/${ENV}.env"
fi

export APP_VERSION
export COMPOSE_PROJECT_NAME="payment-${ENV}"

echo "===== DEPLOY ${ENV} ====="
echo "APP_VERSION=${APP_VERSION}"
echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"

# 1. Vault first
echo "[1/6] Vault up"
vault_attempt=1
vault_max_attempts=3
while ! docker compose up -d --wait vault 2>&1 | tee /tmp/vault-up.log; do
  if grep -q 'port is already allocated' /tmp/vault-up.log; then
    echo "ERROR: port conflict for vault — not retrying, fix the port first" >&2
    docker ps --filter "publish=${VAULT_PORT:-8200}" >&2
    exit 1
  fi
  if [ "$vault_attempt" -ge "$vault_max_attempts" ]; then
    echo "ERROR: vault failed health check after ${vault_max_attempts} attempts" >&2
    docker compose ps vault || true
    docker compose logs --no-color vault || true
    exit 1
  fi
  echo "WARN: vault failed (attempt ${vault_attempt}/${vault_max_attempts}), retrying..." >&2
  docker compose rm -sf vault >/dev/null 2>&1 || true
  vault_attempt=$((vault_attempt + 1))
  sleep 3
done

# --- Seed Vault + render runtime.env (db/rabbitmq need these values) ---
echo "[1.5/6] Seeding Vault + rendering runtime.env"
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV"

if [ ! -s runtime.env ]; then
  echo "ERROR: runtime.env is empty after render-env.sh — Vault seed/render failed" >&2
  echo "--- runtime.env ---" >&2
  ls -la runtime.env >&2 || true
  echo "--- vault status ---" >&2
  docker compose ps vault >&2 || true
  echo "--- vault logs (last 100) ---" >&2
  docker compose logs --tail=100 vault >&2 || true
  exit 1
fi
echo "runtime.env OK ($(wc -c < runtime.env) bytes)"

# 2. Data plane
echo "[2/6] db + rabbitmq up"
if ! docker compose up -d --wait db rabbitmq; then
  echo "" >&2
  echo "ERROR: db or rabbitmq failed to become healthy. Diagnostics:" >&2
  echo "--- compose ps ---" >&2
  docker compose ps >&2 || true
  echo "--- db logs (last 200) ---" >&2
  docker compose logs --tail=200 db >&2 || true
  echo "--- db inspect ---" >&2
  DB_ID=$(docker compose ps -q db 2>/dev/null)
  if [ -n "$DB_ID" ]; then
    docker inspect "$DB_ID" --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' >&2 || true
  fi
  echo "--- rabbitmq logs (last 200) ---" >&2
  docker compose logs --tail=200 rabbitmq >&2 || true
  echo "--- rabbitmq inspect ---" >&2
  RMQ_ID=$(docker compose ps -q rabbitmq 2>/dev/null)
  if [ -n "$RMQ_ID" ]; then
    docker inspect "$RMQ_ID" --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' >&2 || true
    docker inspect "$RMQ_ID" --format '{{json .State.Health}}' 2>/dev/null | head -c 2000 >&2 || true
    echo "" >&2
  fi
  echo "--- runtime.env (redacted) ---" >&2
  sed 's/=.*/=<redacted>/' runtime.env >&2 2>/dev/null || echo "(no runtime.env)" >&2
  exit 1
fi

# 3. Migrations BEFORE app rollout (see RUNBOOK.md § Откат)
echo "[3/6] Applying migrations"
./migrate.sh

# 4. Resolve application images:
#    a) IMAGE_REGISTRY set  → pull from registry, retag as northwind/*
#    b) local image exists  → use it
#    c) otherwise           → build from source
echo "[4/6] Resolving application images"
for svc in api worker mock-provider; do
  case "$svc" in
    api)           LOCAL="northwind/payment-api:${APP_VERSION}" ;;
    worker)        LOCAL="northwind/payment-worker:${APP_VERSION}" ;;
    mock-provider) LOCAL="northwind/mock-provider:${APP_VERSION}" ;;
  esac

  if [ -n "${IMAGE_REGISTRY:-}" ]; then
    REMOTE="${IMAGE_REGISTRY}/${svc}:${APP_VERSION}"
    if docker pull "$REMOTE" >/dev/null 2>&1; then
      docker tag "$REMOTE" "$LOCAL"
      echo "  ${svc}: pulled ${REMOTE} → ${LOCAL}"
      continue
    fi
    echo "  ${svc}: pull ${REMOTE} failed — falling back to local/build" >&2
  fi

  if docker image inspect "$LOCAL" >/dev/null 2>&1; then
    echo "  ${svc}: using local ${LOCAL}"
    continue
  fi

  echo "  ${svc}: building locally (no registry image, none cached)"
  docker compose build "$svc"
done

# 5. Rollout — idempotent, no destructive 'down'
echo "[5/6] Rolling out"
if [ -n "${IMAGE_REGISTRY:-}" ]; then
  docker compose up -d --remove-orphans
else
  docker compose up -d --remove-orphans --build
fi

# 6. Record success
echo "[6/6] Recording version"
echo "$APP_VERSION" > "$CURRENT_FILE"
echo "===== DEPLOY ${ENV} OK: ${APP_VERSION} ====="