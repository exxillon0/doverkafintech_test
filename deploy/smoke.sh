#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <stage|prod>" >&2
  exit 1
fi

cd "$(dirname "$0")"
touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export COMPOSE_PROJECT_NAME="payment-${ENV}"

echo "===== SMOKE ${ENV} ====="

# 1. API /health — inside the container, since api doesn't publish 8000 to host
for i in $(seq 1 30); do
  if docker compose exec -T api python -c \
     "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2)" 2>/dev/null; then
    echo "OK: api /health"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "FAIL: api /health not ready after 60s" >&2
    docker compose logs --tail=100 api || true
    exit 1
  fi
  sleep 2
done

# 2. DB readiness
docker compose exec -T db pg_isready -U payments -d payments >/dev/null
echo "OK: db pg_isready"

# 3. Reverse-proxy (non-fatal — nginx may not expose /health)
if curl -fsS "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  echo "OK: reverse-proxy /health"
else
  echo "WARN: reverse-proxy /health not reachable at :${API_PORT:-8080}" >&2
fi

# 4. Worker alive
if docker compose ps worker | grep -q "Up"; then
  echo "OK: worker running"
else
  echo "FAIL: worker not running" >&2
  docker compose logs --tail=50 worker || true
  exit 1
fi

echo "===== SMOKE ${ENV} PASSED ====="