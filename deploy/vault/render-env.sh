#!/usr/bin/env bash
ENV="${1:?usage: render-env.sh <env>}"
cd "$(dirname "$0")/.."

get() {
  docker compose exec -T vault vault kv get -field="$1" "secret/payment-stack/$ENV" 2>/dev/null || true
}

cat > runtime.env <<EOT
POSTGRES_PASSWORD=$(get db_password)
RABBITMQ_DEFAULT_PASS=$(get rabbitmq_password)
PROVIDER_API_KEY=$(get provider_api_key)
EOT
