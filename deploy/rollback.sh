#!/usr/bin/env bash
set -e

VERSION="${1:?usage: rollback.sh <version>}"
cd "$(dirname "$0")"
APP_VERSION="$VERSION" docker compose up -d --no-build --no-deps api worker
docker compose restart reverse-proxy
