#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?usage: render-env.sh <env>}"
cd "$(dirname "$0")/.."

echo "📝 Rendering runtime.env from Vault for $ENV..."

get() {
    docker compose exec -T vault vault kv get -field="$1" "secret/payment-stack/$ENV" 2>/dev/null || true
}

DB_PASS=$(get db_password)
RMQ_PASS=$(get rabbitmq_password)
PROVIDER_KEY=$(get provider_api_key)

if [[ -z "$DB_PASS" || -z "$RMQ_PASS" ]]; then
    echo "⚠️  Vault not ready — writing defaults to runtime.env"
    cat > runtime.env <<EOT
POSTGRES_PASSWORD=db_password_123
RABBITMQ_DEFAULT_PASS=rabbit_password_123
PROVIDER_API_KEY=provider_api_key_123
EOT
    exit 0
fi

cat > runtime.env <<EOT
POSTGRES_PASSWORD=$DB_PASS
RABBITMQ_DEFAULT_PASS=$RMQ_PASS
PROVIDER_API_KEY=$PROVIDER_KEY
EOT

echo "✅ runtime.env generated:"
cat runtime.env
