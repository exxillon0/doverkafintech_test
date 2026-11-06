#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p ../backups
FILE="../backups/payments-$(date +%Y%m%d-%H%M%S).sql"
docker compose exec -T db pg_dump -U payments -d postgres > "$FILE"
echo "$FILE"
