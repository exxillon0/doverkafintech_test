#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?usage: seed.sh <env>}"
cd "$(dirname "$0")/.."

# Enable KV v2 secrets engine - this is required before any kv operations
echo "🔐 Enabling KV v2 secrets engine..."
docker compose exec -T vault vault secrets enable -version=2 kv 2>/dev/null || {
    echo "⚠️  KV engine may already be enabled"
}

# Wait for KV engine to be ready
for i in $(seq 1 10); do
    if docker compose exec -T vault vault secrets list -format=json 2>/dev/null | grep -q "kv"; then
        echo "✅ KV v2 engine is enabled"
        break
    fi
    if [[ $i -eq 10 ]]; then
        echo "⚠️  KV v2 engine not ready after 10 attempts, proceeding anyway"
        break
    fi
    sleep 1
done

# Check if secrets already exist (idempotent)
if docker compose exec -T vault vault kv get "secret/payment-stack/$ENV" >/dev/null 2>&1; then
    echo "✅ Secrets already configured for $ENV — skipping re-seed"
    exit 0
fi

# Load base .env (contains placeholder secrets)
echo "📦 Loading base .env configuration..."
if [[ -f .env ]]; then
    set -a
    . ./.env
    set +a
fi

# Store secrets in Vault KV v2
echo "🔐 Seeding Vault secrets for $ENV..."
docker compose exec -T vault vault kv put "secret/payment-stack/$ENV" \
    db_password="${DB_PASSWORD:-nw-tes…91c2}" \
    rabbitmq_password="${RABBITMQ_PASSWORD:-nw-tes…13ef}" \
    provider_api_key="${PROVIDER_API_KEY:-nw-tes…bb42}" >/dev/null

echo "✅ Vault seeded successfully for $ENV"
echo "   Secrets path: secret/payment-stack/$ENV"
echo "   DB password: ${DB_PASSWORD:-nw-tes…91c2}"
echo "   RabbitMQ password: ${RABBITMQ_PASSWORD:-nw-tes…13ef}"