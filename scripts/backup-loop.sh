#!/usr/bin/env bash
# Простой loop: бэкап раз в INTERVAL_SEC секунд (для systemd/cron-обёртки).
# В проде лучше использовать systemd timer или cron, а этот скрипт — для demo.
set -euo pipefail

ENV="${1:-stage}"
INTERVAL_SEC="${INTERVAL_SEC:-86400}"  # 24h

while true; do
  echo "[backup-loop] $(date -u +%FT%TZ) starting backup for ${ENV}"
  "$(dirname "$0")/backup.sh" "$ENV" || echo "[backup-loop] backup failed, retry next interval"
  echo "[backup-loop] sleeping ${INTERVAL_SEC}s"
  sleep "$INTERVAL_SEC"
done
