#!/usr/bin/env bash
# Проверенное восстановление: восстанавливает последний бэкап в temp БД,
# сравнивает count(*), дропает temp БД. Не трогает боевую БД.
set -euo pipefail

ENV="${1:-stage}"
BACKUP_FILE="${2:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"

cd "${REPO_ROOT}/deploy"
touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export COMPOSE_PROJECT_NAME="payment-${ENV}"

# Если бэкап не указан — берём самый свежий
if [ -z "$BACKUP_FILE" ]; then
  BACKUP_FILE=$(ls -1t "${BACKUP_DIR}"/payments-${ENV}-*.sql.gz 2>/dev/null | head -n1 || true)
fi
if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: no backup found for ${ENV} in ${BACKUP_DIR}" >&2
  echo "       Run: make backup ENV=${ENV}" >&2
  exit 1
fi

# Замораживаем состояние: останавливаем worker, чтобы не было новых transfers во время drill
WAS_RUNNING=$(docker compose -p "payment-${ENV}" ps worker --status running -q 2>/dev/null | head -n1 || true)
cleanup() {
  if [ -n "$WAS_RUNNING" ]; then
    echo "[drill] resuming worker"
    docker compose -p "payment-${ENV}" start worker > /dev/null 2>&1 || true
  fi
  if [ -n "${TARGET_DB:-}" ]; then
    docker compose -p "payment-${ENV}" exec -T db psql -U payments -d postgres \
      -c "DROP DATABASE IF EXISTS ${TARGET_DB} WITH (FORCE)" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -n "$WAS_RUNNING" ]; then
  echo "[drill] stopping worker to freeze DB state"
  docker compose -p "payment-${ENV}" stop worker > /dev/null
fi

TARGET_DB="payments_restore_verify_$(date +%s)"
echo "[drill] env=${ENV} backup=${BACKUP_FILE}"
echo "[drill] temp_db=${TARGET_DB}"

# Count в источнике
ORIG=$(docker compose -p "payment-${ENV}" exec -T db psql -tA -U payments -d payments \
  -c "SELECT count(*) FROM transfers" | tr -d '[:space:]')
echo "[drill] source transfers: ${ORIG}"

# Создать temp БД и восстановить
docker compose -p "payment-${ENV}" exec -T db psql -U payments -d postgres \
  -c "CREATE DATABASE ${TARGET_DB}" > /dev/null

gunzip -c "$BACKUP_FILE" | \
  docker compose -p "payment-${ENV}" exec -T db psql -U payments -d "$TARGET_DB" \
  -v ON_ERROR_STOP=1 --quiet > /dev/null

# Count после восстановления
RESTORED=$(docker compose -p "payment-${ENV}" exec -T db psql -tA -U payments -d "$TARGET_DB" \
  -c "SELECT count(*) FROM transfers" | tr -d '[:space:]')
echo "[drill] restored transfers: ${RESTORED}"

# Проверки
OK=1
[ "$ORIG" = "$RESTORED" ] || { echo "[drill] FAIL: count mismatch (${ORIG} != ${RESTORED})"; OK=0; }

# Доп: проверяем что schema_migrations присутствует
HAS_SM=$(docker compose -p "payment-${ENV}" exec -T db psql -tA -U payments -d "$TARGET_DB" \
  -c "SELECT count(*) FROM schema_migrations" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [ "${HAS_SM:-0}" -lt 1 ]; then
  echo "[drill] FAIL: schema_migrations table missing or empty in restored DB"
  OK=0
else
  echo "[drill] schema_migrations rows: ${HAS_SM}"
fi

if [ "$OK" = "1" ]; then
  echo "[drill] ✅ RESTORE DRILL PASSED"
  exit 0
else
  echo "[drill] ❌ RESTORE DRILL FAILED"
  exit 1
fi
