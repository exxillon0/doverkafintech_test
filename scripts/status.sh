#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/../deploy"
for service in api mock-provider; do
  docker compose ps "$service"
done
