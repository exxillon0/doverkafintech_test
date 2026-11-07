## Откат релиза

### Быстрый откат кода

    make rollback ENV=prod

Читает `deploy/.state/prod.previous_version`, пуллит образы этой версии,
поднимает через `docker compose up -d --remove-orphans`. Не делает `down`.

Автооткат в CI: если `make smoke ENV=prod` падает — workflow вызывает
`make rollback` автоматически.

### Что происходит со схемой БД

**Схема НЕ откатывается автоматически.** Правила:

1. Миграции применяются ДО раскатки кода (`deploy.sh` шаг [3/6]).
2. Политика expand → migrate → contract:
   - релиз N: только ADD COLUMN / CREATE TABLE
   - релиз N+1: код использует новые поля
   - релиз N+2: DROP / RENAME, когда откат на N уже невозможен
3. `migrate.sh` идемпотентен (таблица `schema_migrations`) + `pg_advisory_lock`.
4. Если миграция была ломающей (RENAME/DROP) и нужен откат кода:
   - `make rollback` сломает приложение — не делать
   - восстановить БД из бэкапа, затем `make deploy ENV=prod APP_VERSION=<old-sha>`

### Запрещено
- Править применённые миграции задним числом
- RENAME/DROP в одном релизе с фичами
- `docker compose down -v` в скриптах

## Здоровье сервисов (health/readiness)

API экспортирует четыре эндпоинта:

| Endpoint | Что проверяет | Коды |
|---|---|---|
| `/health` | только процесс (liveness) | 200 всегда |
| `/health/ready` | БД + RabbitMQ | 200 / 503 |
| `/health/db` | только БД (`SELECT 1`) | 200 / 503 |
| `/health/rabbit` | только RabbitMQ (`queue_declare passive`) | 200 / 503 |

**Docker healthcheck смотрит на `/health`** (liveness). При падении БД
контейнер api остаётся `healthy` — рестарт api не починит БД, рестартить
не нужно.

**Smoke после деплоя смотрит на `/health/ready`.** Если api поднялся, но
не видит БД/очередь, smoke упадёт → сработает автооткат.

### Диагностика: «api живой, но 503»

    # что именно сломано?
    docker compose exec -T api python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/db')"
    docker compose exec -T api python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/rabbit')"

Если `/health/db` → 503: проверь `docker compose ps db`, `docker compose logs db`.
Если `/health/rabbit` → 503: проверь `docker compose ps rabbitmq`, `rabbitmq-diagnostics ping`.

### Метрики

`api_dependency_up{dependency="db|rabbit"}` — gauge 1/0. Если 0 дольше
N минут → алерт (Level 4, пока не настроено, см. LIMITS.md § 4.2).


## Ядовитые сообщения и DLQ

Сообщение, которое не удалось обработать `MAX_RETRIES` раз (3) или
которое не парсится (`PoisonMessage`), уходит в очередь `transfers.dlq`.

### Посмотреть DLQ

    docker compose exec rabbitmq rabbitmqadmin list queues name messages
    # или
    docker compose exec rabbitmq rabbitmqctl list_queues name messages

### Достать сообщение из DLQ для разбора

    docker compose exec rabbitmq rabbitmqadmin get queue=transfers.dlq count=1

### Отправить сообщение обратно в основную очередь (replay)

    # после ручного исправления payload
    docker compose exec rabbitmq rabbitmqadmin publish \
      exchange=amq.default routing_key=transfers payload='{"transfer_id":"..."}'

### Почистить DLQ (осторожно!)

    docker compose exec rabbitmq rabbitmqadmin purge queue=transfers.dlq

### Метрики

- `worker_poison_messages_total` — счётчик сообщений, отправленных в DLQ.
- `worker_retries_total` — счётчик повторных попыток.
- Алерт: если `rate(worker_poison_messages_total[5m]) > 0` — сообщения
  уходят в DLQ, требуется ручной разбор (см. `monitoring/rules.yml`).


## Ядовитые сообщения и DLQ

Сообщение уходит в `transfers.dlq` в двух случаях:

1. **PoisonMessage** — битый JSON / нет `transfer_id` / невалидный UUID → сразу в DLQ.
2. **MAX_RETRIES исчерпан** — 3 неудачные попытки с интервалом 5 сек (retry-очередь с TTL).

Метрики: `worker_poison_messages_total` (счётчик), `worker_retries_total`, `worker_dlq_size` (gauge).

### Посмотреть DLQ

    cd deploy
    docker compose exec rabbitmq rabbitmqctl list_queues name messages | grep transfers

### Достать сообщение для разбора

    docker compose exec rabbitmq rabbitmqadmin get queue=transfers.dlq count=1

### Replay (после ручного исправления)

    docker compose exec rabbitmq rabbitmqadmin publish \
      exchange=amq.default routing_key=transfers \
      payload='{"transfer_id":"<uuid>","request_id":"replay-1"}'

### Почистить DLQ (осторожно — сообщения пропадут)

    docker compose exec rabbitmq rabbitmqadmin purge queue=transfers.dlq

### Алерты

- `WorkerDLQGrowing` — сообщения уходят в DLQ прямо сейчас.
- `WorkerDLQNotEmpty` — в DLQ висит что-то дольше 10 минут.
Оба требуют ручного разбора. См. `monitoring/rules.yml`.

## Бэкап и восстановление БД

### Ручной бэкап

    make backup ENV=prod
    # → backups/payments-prod-20261108T120000Z.sql.gz

Проверяется на:
- файл непустой
- валидный gzip (`gzip -t`)
- retention: старые (>7 дней, настраивается `RETENTION_DAYS`) удаляются

### Автоматический (cron на хосте)

    # crontab -e
    0 3 * * * cd /path/to/repo && make backup ENV=prod >> /var/log/payments-backup.log 2>&1

Или через `scripts/backup-loop.sh prod` под systemd. Для тестового задания
cron на хосте достаточен — см. LIMITS § 3.4 (S3 не подключён).

### Проверенное восстановление (restore drill)

**Обязательно после каждого изменения схемы или инфраструктуры БД.**

    make restore-drill ENV=prod

Что делает:
1. Останавливает `worker` (freeze state — новые transfers не появляются).
2. Берёт последний бэкап (или `FILE=...`).
3. Создаёт temp БД `payments_restore_verify_<ts>`.
4. Восстанавливает бэкап в temp БД.
5. Сравнивает `count(*) FROM transfers` source vs restored.
6. Проверяет наличие `schema_migrations`.
7. Дропает temp БД (`WITH (FORCE)`).
8. Возобновляет worker.

Если drill упал — бэкап **невалиден**, restore в проде провалится.
Разбирать до того, как случится инцидент.

### Восстановление на месте (destructive!)

    make restore ENV=prod FILE=backups/payments-prod-20261108T120000Z.sql.gz

- Требует ввода `yes` (защита от опечатки).
- Восстанавливает **поверх** БД `payments`.
- Worker должен быть остановлен: `docker compose -p payment-prod stop worker`.
- **Код не откатывается.** После restore нужен `make deploy ENV=prod APP_VERSION=<sha-из-дампа>`, иначе новый код может быть несовместим со старой схемой.

### Что происходит со схемой

Дамп включает `schema_migrations`. После restore таблица вернётся к прежнему состоянию.
При следующем `make deploy` шаг `[3/6] Applying migrations` применит недостающие миграции.

**Осторожно**: если между дампом и restore были применены ломающие миграции
(`DROP`/`RENAME`), restore + повторная миграция могут конфликтовать.
См. `DECISIONS.md` § expand→contract и `RUNBOOK.md` § Откат релиза.

## Секреты и Vault: что если секрета нет

Vault работает в **dev-режиме** (см. `DECISIONS.md`). Для реального прода
dev-режим непригоден — данные в памяти, аутентификации нет.

### Поведение по окружениям

| Сценарий | Поведение | Зачем |
|---|---|---|
| `ENV=stage` локально | токен из `stage.env.example` (`stage-dev-root`) | demo работает из коробки |
| `ENV=prod` локально без `ALLOW_DEV_VAULT` | `deploy.sh` падает с понятной ошибкой | нельзя случайно задеплоить «прод» с dev-токеном |
| `ENV=prod` локально с `ALLOW_DEV_VAULT=1` | генерируется случайный токен, сохраняется в `prod.env` | demo/защита |
| CI `prod`, секрет задан | реальный токен из GitHub Secrets | правильный путь |
| CI `prod`, секрет не задан, `ALLOW_EPHEMERAL_VAULT_TOKEN=true` (default) | ephemeral токен + `::warning::` | ревьюер клонирует → работает |
| CI `prod`, секрет не задан, `ALLOW_EPHEMERAL_VAULT_TOKEN=false` | fail с `::error::` на шаге `Write prod env from secrets` | реальный прод |

### Как включить «настоящий прод-режим» в CI

Settings → Secrets and variables → Actions → **Variables** → New variable:

- Name: `ALLOW_EPHEMERAL_VAULT_TOKEN`
- Value: `false`

И задать secret `VAULT_DEV_ROOT_TOKEN` с реальным значением.

После этого деплой без секрета падает на шаге `Write prod env from secrets`,
не доходя до `make deploy`.

### Что делать, если Vault перезапустился

Dev-режим Vault хранит данные **в памяти**. При перезапуске контейнера:
- все секреты пропадают
- `runtime.env` остаётся (генерируется `render-env.sh`)
- новые контейнеры подхватят старый `runtime.env`

Восстановить:

    cd deploy
    docker compose -p payment-stage up -d vault
    ./vault/seed.sh stage
    ./vault/render-env.sh stage
    docker compose -p payment-stage up -d --force-recreate api worker

Это автоматически делает `make deploy` (`deploy.sh` шаг `[1/6]`).