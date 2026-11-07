# Payment Stack — Northwind Transfer

Мини-стек международных переводов: HTTP API + worker очереди +
PostgreSQL + RabbitMQ + Vault (dev) + Prometheus, за nginx reverse-proxy.
Всё — Docker Compose v2. Тестовое задание по DevOps: воспроизводимость,
безопасные обновления, наблюдаемость, откат.

Приложение — **backend-only**, без UI. «Клиент» — это `curl` / другая
система. Продукт здесь — инфраструктура вокруг сервисов, а не фронтенд.

## Состав стека

| Сервис | Роль | Порт (host) |
|---|---|---|
| `reverse-proxy` (nginx) | вход, `:8080` → `api:8000` | `8080` (stage) / `80` (prod) |
| `api` (FastAPI/Starlette) | `/transfers`, `/health`, `/metrics` | — (только внутри сети) |
| `worker` (pika) | consumer очереди `transfers` | — (только `/metrics` на 8001 внутри) |
| `db` (PostgreSQL 13.14) | таблица `transfers`, `schema_migrations` | — (только внутри) |
| `rabbitmq` (3.9.29-management) | `transfers`, `transfers.retry`, `transfers.dlq` | `15672` (management UI) |
| `mock-provider` | заглушка «внешнего банка» (HTTPS) | — (только внутри) |
| `vault` (1.15.4, **dev**) | секреты → `runtime.env` | `8200` (только localhost) |
| `prometheus` (v2.50.1) | скрейп `/metrics`, алерты | `9090` (только localhost) |

## Пререквизиты

Единственное, что нужно на машине:

- **Docker Engine ≥ 20.10** с **Compose v2** (`docker compose`, не
  `docker-compose`)
- **make**
- **git**
- **python 3.11+** (только для локального запуска тестов/линтера,
  для запуска стека не нужен)
- **curl** (для smoke)

Всё остальное (образы, зависимости Python, Postgres, RabbitMQ, Vault)
ставится/запускается автоматически через `docker compose`.

## Quickstart (с нуля)

```bash
# 1. Клонировать
git clone https://github.com/exxillon0/doverkafintech_test.git
cd doverkafintech_test

# 2. Права на скрипты (один раз)
chmod +x scripts/*.sh deploy/*.sh deploy/vault/*.sh

# 3. Поднять stage (dev-режим, без настройки секретов)
make deploy ENV=stage APP_VERSION=dev

# 4. Проверить
make smoke ENV=stage
# Ожидаемо: OK: api /health, OK: api /health/ready, OK: db pg_isready,
#           OK: reverse-proxy /health, OK: worker running
#           ===== SMOKE stage PASSED =====


## CI/CD

Доказательство прогона:
- Level 2 (базовый pipeline): https://github.com/exxillon0/doverkafintech_test/actions/runs/42389989594
- Level 3 (DLQ + backup + Vault): https://github.com/exxillon0/doverkafintech_test/actions/runs/42417734882
