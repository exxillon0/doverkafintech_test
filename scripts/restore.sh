#!/usr/bin/env bash
# Восстановление из бэкапа. По умолчанию — в payments (destructive!).
# Для безопасной проверки используй restore-drill.sh или TARGET_DB=temp.
set -euo pipefail

ENV="${1:-}"
BACKUP_FILE="${2:-}"
TARGET_DB="${TARGET_DB:-payments}"

if [ -z "$ENV" ] || [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <stage|prod> <backup-file.sql.gz>" >&2
  echo "  Env: TARGET_DB=<db>     restore target (default: payments)" >&2
  exit 1
fi
if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: backup file not found: $BACKUP_FILE" >&2
  exit 1
fi
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
  echo "ERROR: not a valid gzip: $BACKUP_FILE" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}/deploy"
touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export COMPOSE_PROJECT_NAME="payment-${ENV}"

echo "[restore] env=${ENV} file=${BACKUP_FILE} target_db=${TARGET_DB}"

# Защита от случайного восстановления поверх прод-БД
if [ "$TARGET_DB" = "payments" ]; then
  echo ""
  echo "⚠️  WARNING: restoring over the PRODUCTION database '${TARGET_DB}'!"
  echo "    All current data will be replaced by the dump contents."
  echo "    Worker must be stopped (docker compose stop worker) or it will write to the DB mid-restore."
  echo ""
  printf "Type 'yes' to continue: "
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "aborted"; exit 1; }
fi

# Создать БД если нет
docker compose -p "payment-${ENV}" exec -T db psql -U payments -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" | grep -q 1 || {
  echo "[restore] creating database ${TARGET_DB}"
  docker compose -p "payment-${ENV}" exec -T db psql -U payments -d postgres \
    -c "CREATE DATABASE ${TARGET_DB}"
}

# Восстановление
echo "[restore] restoring..."
gunzip -c "$BACKUP_FILE" | \
  docker compose -p "payment-${ENV}" exec -T db psql -U payments -d "$TARGET_DB" \
  -v ON_ERROR_STOP=1 --quiet > /dev/null

COUNT=$(docker compose -p "payment-${ENV}" exec -T db psql -tA -U payments -d "$TARGET_DB" \
  -c "SELECT count(*) FROM transfers" | tr -d '[:space:]')
echo "[restore] OK: ${TARGET_DB} now has ${COUNT} transfers"
