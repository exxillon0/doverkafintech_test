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
        echo "       Fix: delete secret in Vault and re-seed with ASCII-only passwords:" >&2
        echo "         docker compose exec -T vault vault kv delete secret/payment-stack/$ENV" >&2
        echo "         ./vault/seed.sh $ENV" >&2
        exit 1
    fi
}

if [[ -z "$DB_PASS" || -z "$RMQ_PASS" ]]; then
    echo "⚠️  Vault not ready — writing dev defaults to runtime.env"
    cat > runtime.env <<EOT
POSTGRES_PASSWORD=devpostgres$(gen_ascii_fallback 2>/dev/null || echo -n "0123456789abcdef")
RABBITMQ_DEFAULT_PASS=devrabbit$(gen_ascii_fallback 2>/dev/null || echo -n "0123456789abcdef")
PROVIDER_API_KEY=devprovider$(gen_ascii_fallback 2>/dev/null || echo -n "0123456789abcdef")
EOT
    exit 0
fi

validate_ascii "db_password" "$DB_PASS"
validate_ascii "rabbitmq_password" "$RMQ_PASS"
validate_ascii "provider_api_key" "$PROVIDER_KEY"

cat > runtime.env <<EOT
POSTGRES_PASSWORD=$DB_PASS
RABBITMQ_DEFAULT_PASS=$RMQ_PASS
PROVIDER_API_KEY=$PROVIDER_KEY
EOT

echo "✅ runtime.env generated:"
sed 's/=.*/=<redacted>/' runtime.env