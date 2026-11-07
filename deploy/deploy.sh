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

# 1. Vault first — runtime.env must be rendered before db starts
echo "[1/6] Vault up"
if ! docker compose up -d --wait vault; then
  echo "WARN: vault failed initial health check, retrying once..." >&2
  docker compose ps vault || true
  docker compose logs --no-color vault || true
  docker compose rm -sf vault || true
  docker compose up -d --wait vault
fi
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV"

# 2. Data plane
echo "[2/6] db + rabbitmq up"
docker compose up -d --wait db rabbitmq

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

echo "[5/6] Rolling out"
# --build: пересобрать образы, если Dockerfile/код изменились.
# Для prod (IMAGE_REGISTRY задан) — образы пуллятся, --build не нужен.
if [ -n "${IMAGE_REGISTRY:-}" ]; then
  docker compose up -d --remove-orphans
else
  docker compose up -d --remove-orphans --build
fi
# 6. Record success
echo "[6/6] Recording version"
echo "$APP_VERSION" > "$CURRENT_FILE"
echo "===== DEPLOY ${ENV} OK: ${APP_VERSION} ====="