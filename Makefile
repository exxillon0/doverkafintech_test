ENV ?=
APP_VERSION ?=
ALLOW_DEV_VAULT ?= 0
IMAGE_REGISTRY ?=
FILE ?=

.PHONY: help deploy rollback smoke migrate test lint ci check-env check-version \
        backup restore restore-drill install-dev

help:
	@echo "Targets:"
	@echo "  make deploy        ENV=stage|prod APP_VERSION=<sha>"
	@echo "  make rollback      ENV=stage|prod"
	@echo "  make smoke         ENV=stage|prod"
	@echo "  make migrate"
	@echo "  make backup        ENV=stage|prod"
	@echo "  make restore       ENV=stage|prod FILE=backups/payments-....sql.gz"
	@echo "  make restore-drill ENV=stage|prod [FILE=backups/payments-....sql.gz]"
	@echo "  make test"
	@echo "  make lint"
	@echo "  make ci"
	@echo "  make install-dev"
	@echo ""
	@echo "Local demo (no GitHub Secrets needed):"
	@echo "  make deploy ENV=stage APP_VERSION=dev"
	@echo "  ALLOW_DEV_VAULT=1 make deploy ENV=prod APP_VERSION=dev"

check-env:
	@test -n "$(ENV)" || (echo "ERROR: ENV is required (stage|prod)" >&2; exit 1)

check-version:
	@test -n "$(APP_VERSION)" || (echo "ERROR: APP_VERSION is required" >&2; exit 1)

deploy: check-env check-version
	cd deploy && \
	  APP_VERSION=$(APP_VERSION) \
	  ALLOW_DEV_VAULT=$(ALLOW_DEV_VAULT) \
	  IMAGE_REGISTRY=$(IMAGE_REGISTRY) \
	  ./deploy.sh $(ENV)

rollback: check-env
	cd deploy && ./rollback.sh $(ENV)

smoke: check-env
	cd deploy && ./smoke.sh $(ENV)

migrate:
	cd deploy && ./migrate.sh

backup: check-env
	./scripts/backup.sh $(ENV)

restore: check-env
	@test -n "$(FILE)" || (echo "ERROR: FILE= is required (e.g. backups/payments-stage-....sql.gz)" >&2; exit 1)
	./scripts/restore.sh $(ENV) $(FILE)

restore-drill: check-env
	./scripts/restore-drill.sh $(ENV) $(FILE)

test:
	(cd services/api && python -m pytest tests -v)
	(cd services/worker && python -m pytest tests -v)

lint:
	ruff check services/api/ services/worker/

ci: lint test

install-dev:
	python -m pip install --upgrade pip
	pip install -r services/api/requirements.txt
	pip install -r services/worker/requirements.txt
	pip install ruff pytest httpx