.PHONY: lint test build scan deploy deploy-stage deploy-prod clean

IMAGE_API ?= northwind/payment-api
IMAGE_WORKER ?= northwind/payment-worker
IMAGE_MOCK ?= northwind/mock-provider:local
VERSION ?= 1.0.0

deploy-stage:
	@echo ">>> Deploying to STAGE environment"
	cd deploy && ./deploy.sh stage

deploy-prod:
	@echo ">>> Deploying to PROD environment"
	cd deploy && ./deploy.sh prod

ci: lint test build scan

lint:
	@echo ">>> Running Python lint"
	python -m ruff check services/ || true

test:
	@echo ">>> Running tests"
	pytest services/api/tests services/worker/tests -v

build:
	@echo ">>> Building images"
	docker compose -f deploy/docker-compose.yml build api worker mock-provider

scan:
	@echo ">>> Scanning images"
	docker scan $(IMAGE_API):$(VERSION)
	docker scan $(IMAGE_WORKER):$(VERSION)
	docker scan $(IMAGE_MOCK):$(VERSION)

clean:
	@echo ">>> Cleaning"
	docker compose down -v
