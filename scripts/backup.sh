#!/usr/bin/env bash
# Бэкап БД в backups/payments-<env>-<timestamp>.sql.gz
set -euo pipefail

ENV="${1:-stage}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

mkdir -p "$BACKUP_DIR"

cd "${REPO_ROOT}/deploy"
touch runtime.env
set -a
. "env/${ENV}.env"
set +a
export COMPOSE_PROJECT_NAME="payment-${ENV}"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILE="${BACKUP_DIR}/payments-${ENV}-${TIMESTAMP}.sql.gz"

echo "[backup] env=${ENV} → ${FILE}"

# pg_dump через docker compose exec, без --no-owner/--no-acl оставляет привязку к ролям
# --no-owner --no-acl — переносимо между разными owners
docker compose -p "payment-${ENV}" exec -T db \
  pg_dump -U payments -d payments --no-owner --no-acl \
  | gzip > "$FILE"

# Валидация: файл непустой и валидный gzip
if [ ! -s "$FILE" ]; then
  echo "[backup] ERROR: backup file is empty" >&2
  rm -f "$FILE"
  exit 1
fi
if ! gzip -t "$FILE" 2>/dev/null; then
  echo "[backup] ERROR: backup file is not valid gzip" >&2
  exit 1
fi

SIZE=$(du -h "$FILE" | cut -f1)
LINES=$(gunzip -c "$FILE" | wc -l)
echo "[backup] OK: ${FILE} (${SIZE}, ${LINES} lines)"

# Retention: удалить старые бэкапы этого окружения
DELETED=$(find "$BACKUP_DIR" -name "payments-${ENV}-*.sql.gz" \
  -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l)
[ "$DELETED" -gt 0 ] && echo "[backup] removed ${DELETED} old backup(s) (>${RETENTION_DAYS}d)"

COUNT=$(find "$BACKUP_DIR" -name "payments-${ENV}-*.sql.gz" -type f | wc -l)
echo "[backup] total backups for ${ENV}: ${COUNT}"
