#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?usage: seed.sh <env>}"
cd "$(dirname "$0")/.."

# Enable KV v2 secrets engine
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

# --- ASCII-safe password generation ---
# RabbitMQ/Postgres/Erlang reject non-ASCII bytes in passwords.
# Any Unicode like '…' (U+2026) -> Erlang list_to_binary/1 -> badarg -> container crash.
gen_ascii_password() {
    # [a-zA-Z0-9] only, 32 chars — safe for all DBs/brokers
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
}

# Validate a value is non-empty and ASCII-only
validate_ascii() {
    local name="$1" value="$2"
    if [ -z "$value" ]; then
        echo "ERROR: $name is empty" >&2
        exit 1
    fi
    if ! printf '%s' "$value" | LC_ALL=C grep -qP '^[\x20-\x7E]+$'; then
        echo "ERROR: $name contains non-ASCII characters." >&2
        echo "       Value (hex): $(printf '%s' "$value" | xxd -p)" >&2
        echo "       This breaks RabbitMQ/Erlang. Use ASCII-only passwords." >&2
        exit 1
    fi
}

# Resolve secrets: env > generate. No placeholder defaults with '…'
DB_PASS="${DB_PASSWORD:-$(gen_ascii_password)}"
RMQ_PASS="${RABBITMQ_PASSWORD:-$(gen_ascii_password)}"
PROVIDER_KEY="${PROVIDER_API_KEY:-$(gen_ascii_password)}"

validate_ascii "db_password" "$DB_PASS"
validate_ascii "rabbitmq_password" "$RMQ_PASS"
validate_ascii "provider_api_key" "$PROVIDER_KEY"

echo "🔐 Seeding Vault secrets for $ENV..."
docker compose exec -T vault vault kv put "secret/payment-stack/$ENV" \
    db_password="$DB_PASS" \
    rabbitmq_password="$RMQ_PASS" \
    provider_api_key="$PROVIDER_KEY" >/dev/null

echo "✅ Vault seeded successfully for $ENV"
echo "   Secrets path: secret/payment-stack/$ENV"
echo "   DB password: ${DB_PASS:0:4}…${DB_PASS: -4} (ASCII, 32 chars)"
echo "   RabbitMQ password: ${RMQ_PASS:0:4}…${RMQ_PASS: -4} (ASCII, 32 chars)"
echo "   Provider API key: ${PROVIDER_KEY:0:4}…${PROVIDER_KEY: -4} (ASCII, 32 chars)"