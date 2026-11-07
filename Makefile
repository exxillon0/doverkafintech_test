ENV ?=
APP_VERSION ?=

.PHONY: help deploy rollback smoke migrate test lint ci check-env check-version

help:
	@echo "Targets:"
	@echo "  make deploy   ENV=stage|prod APP_VERSION=<sha>   # deploy"
	@echo "  make rollback ENV=stage|prod                     # roll back to previous"
	@echo "  make smoke    ENV=stage|prod                     # post-deploy smoke"
	@echo "  make migrate                                     # apply SQL migrations"
	@echo "  make test                                        # pytest"
	@echo "  make lint                                        # ruff"
	@echo "  make ci                                          # lint + test"

check-env:
	@test -n "$(ENV)" || (echo "ERROR: ENV is required (stage|prod)" >&2; exit 1)

check-version:
	@test -n "$(APP_VERSION)" || (echo "ERROR: APP_VERSION is required" >&2; exit 1)

deploy: check-env check-version
	cd deploy && APP_VERSION=$(APP_VERSION) ./deploy.sh $(ENV)

rollback: check-env
	cd deploy && ./rollback.sh $(ENV)

smoke: check-env
	cd deploy && ./smoke.sh $(ENV)

migrate:
	cd deploy && ./migrate.sh

test:
	(cd services/api && python -m pytest tests -v)
	(cd services/worker && python -m pytest tests -v)

lint:
	ruff check services/api/ services/worker/

ci: lint test