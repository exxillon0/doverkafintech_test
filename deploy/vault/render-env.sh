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

# --- Validate: RabbitMQ/Erlang/Postgres reject non-ASCII in passwords ---
validate_ascii() {
    local name="$1" value="$2"
    if ! printf '%s' "$value" | LC_ALL=C grep -qP '^[\x20-\x7E]+$'; then
        echo "ERROR: $name from Vault contains non-ASCII characters." >&2
        echo "       Value (hex): $(printf '%s' "$value" | xxd -p)" >&2
        echo "       This breaks RabbitMQ/Erlang (badarg in list_to_binary/1)." >&2
        echo "       Fix: docker compose exec -T vault vault kv delete secret/payment-stack/$ENV" >&2
        echo "            ./vault/seed.sh $ENV" >&2
        exit 1
    fi
}

# --- Fallback: Vault returned empty (Vault down or secret missing) ---
# Deterministic ASCII defaults → repeated deploys don't invalidate existing volumes.
if [[ -z "$DB_PASS" || -z "$RMQ_PASS" ]]; then
    echo "⚠️  Vault returned empty secrets for $ENV — using fixed dev defaults" >&2
    echo "    (check deploy.sh [1.5/6]: seed.sh should run before render-env.sh)" >&2
    DB_PASS="devpostgres0123456789abcdef"
    RMQ_PASS="devrabbit0123456789abcdef"
    PROVIDER_KEY="devprovider0123456789abcdef"
fi

# Validate BEFORE writing runtime.env — no exceptions, no fallback bypass
validate_ascii "db_password" "$DB_PASS"
validate_ascii "rabbitmq_password" "$RMQ_PASS"
validate_ascii "provider_api_key" "$PROVIDER_KEY"

cat > runtime.env <<EOT
POSTGRES_PASSWORD=$DB_PASS
RABBITMQ_DEFAULT_PASS=$RMQ_PASS
PROVIDER_API_KEY=$PROVIDER_KEY
EOT

echo "✅ runtime.env generated ($(wc -c < runtime.env) bytes):"
sed 's/=.*/=<redacted>/' runtime.env