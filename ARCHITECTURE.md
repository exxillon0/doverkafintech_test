# ARCHITECTURE — схема стека, поток деплоя, границы доверия

Документ отвечает на три вопроса: **что где работает**, **как код
попадает в прод**, **где проходят границы доверия**. Детали решений —
в `DECISIONS.md`, эксплуатация — в `RUNBOOK.md`.

---

## 1. Стек: компоненты и связи
┌──────────────────────────────┐
│ Client (curl) │
└──────────────┬───────────────┘
│ HTTP :8080 (stage) / :80 (prod)
▼
┌──────────────────────────────┐
│ reverse-proxy (nginx) │
│ proxy_pass → api:8000 │
└──────────────┬───────────────┘
│
▼
┌────────────────────────────────────────────┐
│ api (Starlette) │
│ POST /transfers → INSERT + publish │
│ GET /transfers/{id} → SELECT │
│ GET /health{,/ready,/db,/rabbit} │
│ GET /metrics (Prometheus) │
└──────┬──────────────────────┬──────────────┘
│ │
psycopg │ │ pika (publish)
▼ ▼
┌────────────────────┐ ┌──────────────────────────┐
│ PostgreSQL 13.14 │ │ RabbitMQ 3.9.29 │
│ db │ │ transfers │
│ - transfers │ │ transfers.retry (TTL 5s)│
│ - schema_migrations│ │ transfers.dlq │
└─────────┬──────────┘ └────────────┬─────────────┘
│ │
│ psycopg │ pika (consume)
▼ ▼
┌────────────────────────────────────────────┐
│ worker (pika consumer) │
│ FOR UPDATE → send_payout → UPDATE status │
│ retry / DLQ / metrics на :8001 │
└──────────────────┬─────────────────────────┘
│ HTTPS (self-signed)
▼
┌────────────────────────────────────────────┐
│ mock-provider (FastAPI, TLS :9443) │
│ заглушка «внешнего банка» │
└────────────────────────────────────────────┘

┌────────────────────────────────────────────┐
│ Vault (dev) ── seed/render → runtime.env │
│ Prometheus ── scrape api:8000, worker:8001│
└────────────────────────────────────────────┘
text


**Все контейнеры — в одной Docker-сети** (`payment-<env>_default`).
Наружу опубликованы только `reverse-proxy` (HTTP), `rabbitmq` management
UI, `vault` UI и `prometheus` — и только на `127.0.0.1`.

---

## 2. Поток запроса: `POST /transfers`

    Client → nginx:8080 → api:8000
    nginx принимает HTTP, проксирует в api, пробрасывает
    X-Request-ID (middleware в api генерирует, если нет).

    api (async)

        parse_transfer(body) → валидация (amount, currency, recipient)

        psycopg.connect → INSERT INTO transfers (status=PENDING)

        SELECT только что вставленной строки → 202 JSON клиенту

        broker.publish({"transfer_id": ..., "request_id": ...})
        → RabbitMQ, очередь "transfers" (durable, delivery_mode=2)

    worker (sync, pika.BlockingConnection)

        channel.basic_consume("transfers")

        parse_message(body) → transfer_id (UUID)

        BEGIN; SELECT ... FOR UPDATE (row lock на перевод)

        если status != PENDING → skip (идемпотентность при рестарте)

        send_payout(provider) → HTTPS к mock-provider

        UPDATE transfers SET status=COMPLETED, provider_reference=...

        COMMIT

        basic_ack

    при ошибке:

        PoisonMessage (битый JSON) → transfers.dlq (сразу)

        иначе (transient) → transfers.retry (TTL 5s),
        x-retry-count += 1
        после MAX_RETRIES=3 → DLQ

    Client может опросить
    GET /transfers/{id} → api:8000 → SELECT

text


**Идемпотентность.** Если worker упадёт между `send_payout` и `UPDATE`,
сообщение вернётся из RabbitMQ. При повторной обработке
`status != PENDING` → worker пропустит отправку. Проверка — под
`FOR UPDATE` в одной транзакции с `UPDATE`.

**Трассировка.** `X-Request-ID` (от клиента или сгенерированный в api)
попадает:
- в ответ (header `X-Request-ID`),
- в payload RabbitMQ (`request_id`),
- в каждую JSON-строку лога api и worker (`"request_id":"..."`).

End-to-end: `docker compose logs api worker | grep '"request_id":"<id>"'`.

---

## 3. Поток деплоя: от `git push` до прода

┌─────────────────────────────────────────────────────────────────┐
│ 1. Developer: git push origin main │
└───────────────────────────┬─────────────────────────────────────┘
▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. CI job (GitHub Actions, ubuntu-latest) │
│ - make lint (ruff) │
│ - make test (pytest, api + worker) │
│ - make ci = lint + test │
│ - docker compose build api worker mock-provider │
│ - docker tag → ghcr.io/<repo>/<svc>:<sha> │
│ - docker push → GHCR │
│ - trivy image (CRITICAL — gate, HIGH — лог) │
│ │
│ Артефакт: три образа с тегом = git SHA. │
└───────────────────────────┬─────────────────────────────────────┘
▼ (только на push в main)
┌─────────────────────────────────────────────────────────────────┐
│ 3. CD job (GitHub Actions, отдельный runner) │
│ - docker login GHCR │
│ - Write deploy/env/prod.env из GitHub Secrets/Variables │
│ - make deploy ENV=prod APP_VERSION=$SHA │
│ └─ deploy.sh: │
│ [1/6] up vault → seed → render runtime.env │
│ [2/6] up db + rabbitmq (--wait, healthy) │
│ [3/6] migrate.sh ← МИГРАЦИИ ДО РАСКАТКИ │
│ [4/6] resolve images (pull из GHCR / build локально) │
│ [5/6] up -d --remove-orphans ← идемпотентная раскатка │
│ [6/6] сохранить APP_VERSION в .state/ │
│ - make smoke ENV=prod │
│ └─ /health → /health/ready → pg_isready → worker running │
│ - при провале smoke → make rollback ENV=prod (автооткат) │
│ - сохранить .state/ в actions/cache (для следующего отката) │
└───────────────────────────┬─────────────────────────────────────┘
▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Прод работает │
│ - api/worker на новом SHA │
│ - схема БД — expand → migrate → contract (см. DECISIONS §2) │
│ - при инциденте → RUNBOOK.md § 3–5 │
└─────────────────────────────────────────────────────────────────┘
text


**Ключевые принципы потока:**

| Принцип | Как реализовано |
|---|---|
| Одна команда локально и в CI | `make deploy ENV=… APP_VERSION=…` — вызывается из CI и разработчиком |
| Миграции **до** раскатки | `deploy.sh` § `[3/6]` перед `[5/6]` |
| Идемпотентность | `docker compose up -d --remove-orphans`, **без `down`** |
| Атомарность образов | тег = git SHA, просканированные образы = задеплоенные |
| Автооткат | smoke fail → `make rollback`, `.state/` в cache |
| Без секретов в образах | `runtime.env` генерируется из Vault, не в образе |

---

## 4. Границы доверия

┌──────────────────────────────────────────────────────────────────┐
│ ZONE 0 — PUBLIC INTERNET │
│ Клиент. Всё, что приходит снаружи — недоверенное. │
└──────────────────────────────┬───────────────────────────────────┘
│ HTTP :8080 / :80
▼
┌──────────────────────────────────────────────────────────────────┐
│ ZONE 1 — EDGE (nginx reverse-proxy) │
│ Принимает HTTP, проксирует в api. │
│ В проде — TLS-терминация (сейчас HTTP; см. LIMITS). │
│ Никаких секретов, кроме сетевого доступа к api:8000. │
└──────────────────────────────┬───────────────────────────────────┘
│ HTTP внутри Docker-сети
▼
┌──────────────────────────────────────────────────────────────────┐
│ ZONE 2 — APP (api, worker, mock-provider) │
│ Доверенные сервисы. Доступ к Vault через VAULT_DEV_ROOT_TOKEN. │
│ Секреты приходят через env (runtime.env), НЕ из образов. │
│ api — единственный, кто отвечает клиенту. │
└──────────────────────────────┬───────────────────────────────────┘
│ psycopg / pika
▼
┌──────────────────────────────────────────────────────────────────┐
│ ZONE 3 — DATA (PostgreSQL, RabbitMQ) │
│ Хранят данные переводов и сообщения. │
│ Пароли — из Vault (seed.sh → render-env.sh → runtime.env). │
│ Ports наружу: только rabbitmq management UI (127.0.0.1). │
└──────────────────────────────┬───────────────────────────────────┘
│ HTTPS (self-signed)
▼
┌──────────────────────────────────────────────────────────────────┐
│ ZONE 4 — EXTERNAL (mock-provider) │
│ Заглушка «внешнего банка». Сертификат self-signed, │
│ ssl._create_unverified_context() в worker — только для demo. │
│ Для реального прода — provider CA + mTLS (см. LIMITS). │
└──────────────────────────────────────────────────────────────────┘
text


### Где хранятся секреты

| Что | Откуда | Куда | Вид |
|---|---|---|---|
| `POSTGRES_PASSWORD` | Vault `secret/payment-stack/<env>` | `runtime.env` → `POSTGRES_PASSWORD` | env в контейнере |
| `RABBITMQ_DEFAULT_PASS` | Vault | `runtime.env` | env в контейнере |
| `PROVIDER_API_KEY` | Vault | `runtime.env` | env в контейнере |
| `VAULT_DEV_ROOT_TOKEN` | `stage.env.example` (dev) / GitHub Secret (CI prod) | `deploy/env/<env>.env` | env в контейнере Vault |
| `GITHUB_TOKEN` | GitHub Actions | `docker/login-action` | не персистится |

**Что точно не хранится в git:** реальные пароли, токены, ключи.
`.gitignore` исключает `deploy/env/*.env`, `deploy/runtime.env`,
`deploy/.state/`.

**Что хранится в git:** `.env.example` с плейсхолдерами и dev-токенами
(`stage-dev-root`, `CHANGE_ME_IN_CI`) — это не секреты, а шаблоны.

### Сетевые границы

- **Docker network `payment-<env>_default`:** api ↔ worker ↔ db ↔ rabbitmq
  ↔ mock-provider. Все по именам сервисов (DNS внутри compose).
- **Наружу (`127.0.0.1:<port>`):** reverse-proxy, vault UI,
  rabbitmq management, prometheus — только для оператора на хосте.
- **В интернет:** worker → mock-provider (HTTPS, self-signed, demo);
  CI → GHCR (docker push/pull).

### Границы доверия — явные ограничения

1. **Vault в dev-режиме** — `VAULT_DEV_ROOT_TOKEN` не аутентифицирует,
   данные в памяти. Для прода небезопасно (см. `LIMITS § 2.1`).
2. **mock-provider с self-signed** — `ssl._create_unverified_context()`
   в worker. Для прода — provider CA (см. `LIMITS`).
3. **Одна реплика api/worker** — нельзя показать zero-downtime
   (см. `LIMITS § 5.2`).
4. **Без TLS на nginx** — в проде нужен сертификат (см. `LIMITS`).

---

## 5. Наблюдаемость

| Что | Где | Кто скрейпит |
|---|---|---|
| `api_requests_total{method,path,status}` | api `/metrics` | Prometheus |
| `api_dependency_up{dependency}` | api `/metrics` | Prometheus |
| `worker_messages_total{result}` | worker `/metrics` | Prometheus |
| `worker_poison_messages_total` | worker `/metrics` | Prometheus |
| `worker_dlq_size` | worker `/metrics` | Prometheus |
| Health endpoints | api `/health{,/ready,/db,/rabbit}` | docker healthcheck + smoke |
| Логи (JSON + `request_id`) | stdout | `docker compose logs` |

**Алерты** (`monitoring/rules.yml`): `WorkerDLQGrowing`,
`WorkerDLQNotEmpty`, `ApiDependencyDown`, `WorkerSilent`. Считаются
Prometheus, **alertmanager не настроен** — см. `LIMITS § 4.2`.

**Что не реализовано** — Level 4 (бизнес-метрики, мета-мониторинг,
Grafana-дашборд) — в `LIMITS § 4`.

---

## 6. Ссылки

- Решения с обоснованием — `DECISIONS.md`.
- «Что делать, если…» — `RUNBOOK.md`.
- Границы решения — `LIMITS.md`.
- Как развернуть — `README.md`.



