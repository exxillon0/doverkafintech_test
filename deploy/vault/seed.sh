#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?usage: seed.sh <env>}"
cd "$(dirname "$0")/.."

if docker compose exec -T vault vault kv get "secret/payment-stack/$ENV" >/dev/null 2>&1; then
  exit 0
fi

. ./.env

docker compose exec -T vault vault kv put "secret/payment-stack/$ENV" \
  db_password="$DB_PASSWORD" \
  rabbitmq_password="$RABBITMQ_PASSWORD" \
  provider_api_key="$PROVIDER_API_KEY" >/dev/null
