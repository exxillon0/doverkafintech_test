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

# 1. Liveness /health — api-процесс жив
for i in $(seq 1 30); do
  if docker compose exec -T api python -c \
     "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2)" 2>/dev/null; then
    echo "OK: api /health (liveness)"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "FAIL: api /health not ready after 60s" >&2
    docker compose logs --tail=100 api || true
    exit 1
  fi
  sleep 2
done

# 2. Readiness /health/ready — api видит БД и RabbitMQ
READY=0
for i in $(seq 1 15); do
  if docker compose exec -T api python -c \
     "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/ready', timeout=3)" 2>/dev/null; then
    echo "OK: api /health/ready (readiness)"
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" != "1" ]; then
  echo "FAIL: api /health/ready never became 200" >&2
  echo "--- /health/db:" >&2
  docker compose exec -T api python -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/db', timeout=3)" >&2 || true
  echo "--- /health/rabbit:" >&2
  docker compose exec -T api python -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/rabbit', timeout=3)" >&2 || true
  docker compose logs --tail=100 api || true
  exit 1
fi

# 3. DB readiness
docker compose exec -T db pg_isready -U payments -d payments >/dev/null
echo "OK: db pg_isready"

# 4. Reverse-proxy (non-fatal — nginx может не экспозить /health)
if curl -fsS "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  echo "OK: reverse-proxy /health"
else
  echo "WARN: reverse-proxy /health not reachable at :${API_PORT:-8080}" >&2
fi

# 5. Worker alive
if docker compose ps worker --status running 2>/dev/null | grep -q worker; then
  echo "OK: worker running"
else
  echo "FAIL: worker not running" >&2
  docker compose logs --tail=50 worker || true
  exit 1
fi

echo "===== SMOKE ${ENV} PASSED ====="