#!/usr/bin/env bash
set -e

ENV="${1:-stage}"
cd "$(dirname "$0")"
SERVICES="api worker mock-provider"

touch runtime.env
set -a
. "env/$ENV.env"
set +a

docker compose down -v
docker compose up -d --wait vault
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV"
docker compose build $SERVICES

docker compose up -d --remove-orphans

for service in $SERVICES; do
  docker compose ps "$service"
done
