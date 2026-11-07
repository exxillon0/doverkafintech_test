# RUNBOOK — Payment Stack

«Что делать, если…»: деплой, откат, инциденты, восстановление.
Окружения: `stage` (локально, demo), `prod` (CI). Все команды выполняются
из корня репозитория. Проект compose: `payment-stage` / `payment-prod`.

---

## 1. Здоровье сервисов: liveness vs readiness

API экспортирует четыре эндпоинта:

| Endpoint | Что проверяет | Коды |
|---|---|---|
| `/health` | только процесс (liveness) | 200 всегда |
| `/health/ready` | БД + RabbitMQ | 200 / 503 |
| `/health/db` | только БД (`SELECT 1`) | 200 / 503 |
| `/health/rabbit` | только RabbitMQ (`queue_declare passive`) | 200 / 503 |

**Docker healthcheck** у api смотрит на `/health` (liveness). При падении
БД контейнер api остаётся `healthy` — рестарт api не починит БД, рестартить
не нужно (см. `DECISIONS.md` § Liveness vs Readiness).

**Smoke после деплоя** (`make smoke ENV=<env>`) смотрит на `/health/ready`.
Если api поднялся, но не видит БД/очередь — smoke падает → срабатывает
автооткат в CI.

**Worker** healthcheck — `python`-однострочник на `http://localhost:8001/metrics`.
`prometheus_client` отдаёт 200 даже при потере pika-соединения, поэтому
healthcheck worker'а — это «процесс жив», не «очередь доступна».

---

## 2. Диагностика: api отдаёт 503, но контейнеры живы

    # что именно сломано?
    docker compose -p payment-stage exec -T api python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/db')"
    docker compose -p payment-stage exec -T api python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/rabbit')"

Возможные исходы:

- `/health/db` → 503, `/health/rabbit` → 200 → упала БД (см. § 3).
- `/health/db` → 200, `/health/rabbit` → 503 → упала очередь (см. § 4).
- Оба 503 → проблема с сетью docker:
  `docker network ls`, `docker compose -p payment-stage ps`.

Метрика `api_dependency_up{dependency="db|rabbit"}` (gauge 1/0) — то же
самое для Prometheus. Алерт `ApiDependencyDown` в `monitoring/rules.yml`.

---

## 3. Что делать, если упала БД

### Симптомы

- `make smoke ENV=<env>` падает на `/health/ready (readiness)`.
- `api /health/ready` → `503 {"status":"degraded","checks":{"db":{"ok":false,...}}}`.
- `api /health` → 200 (liveness жив).
- `docker compose -p payment-<env> ps db` → `Exited` или `Restarting`.
- Логи api: `"msg":"dependency check failed","dependency":"db"`.
- Метрика `api_dependency_up{dependency="db"} = 0`.

### Почему api не падает

`/health` (liveness) **всегда 200** — процесс api жив. Рестарт api не починит
БД, поэтому `restart: unless-stopped` api не дёргается. Docker healthcheck
смотрит на `/health`, контейнер остаётся `healthy`, но реальные
`POST /transfers` падают с 500 (psycopg.connect).

Это **намеренно** (см. `DECISIONS.md` § Liveness vs Readiness): падение
БД — не повод рестартить api.

### Что делать

    # 1. Проверить статус и логи
    docker compose -p payment-stage ps db
    docker compose -p payment-stage logs --tail=100 db

    # 2. Поднять
    docker compose -p payment-stage up -d db

    # 3. Дождаться healthy (5–10 сек)
    sleep 10
    docker compose -p payment-stage exec -T api python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/ready')"

    # 4. Убедиться, что smoke проходит
    make smoke ENV=stage

    # 5. Проверить, что worker продолжил обработку
    docker compose -p payment-stage logs --tail=20 worker

Если `db` не поднимается — `docker volume inspect payment-stage_pgdata`
(жив ли volume), `docker compose logs db` (ошибки Postgres).
**Не делать** `docker compose down -v` — это удалит данные
(см. LIMITS § 3.4 — бэкап обязателен).

### Если БД упала в проде и volume повреждён

    # 1. Автооткат уже случился в CI (smoke failed → make rollback)
    # 2. Восстановить БД из бэкапа
    make restore ENV=prod FILE=backups/payments-prod-<...>.sql.gz

    # 3. Раскатать версию кода, совместимую с дампом
    make deploy ENV=prod APP_VERSION=<sha-из-дампа>

---

## 4. Что делать, если упала очередь (RabbitMQ)

### Симптомы

- `api /health/ready` → 503, `checks.rabbit.ok = false`.
- Логи api: `"msg":"dependency check failed","dependency":"rabbit"`.
- `POST /transfers` → 500 (broker.publish → pika → connection refused).
- Метрика `api_dependency_up{dependency="rabbit"} = 0`.

### Поведение worker при падении очереди

`worker` использует `pika.BlockingConnection` и `start_consuming()`.
При падении RabbitMQ:

1. `start_consuming()` бросает `AMQPConnectionError` → процесс worker
   завершается с exit code ≠ 0.
2. `restart: unless-stopped` перезапускает worker.
3. Worker снова пытается подключиться → если RabbitMQ лежит, снова падает.
4. **Restart loop** до восстановления RabbitMQ. В логах
   `docker compose logs worker` — серия `pika.exceptions.AMQPConnectionError`.

Это не идеально (нет экспоненциального backoff), но приемлемо для одной
машины. Записано в `LIMITS.md` § 3.2.

### Что делать

    # 1. Проверить
    docker compose -p payment-stage ps rabbitmq
    docker compose -p payment-stage logs --tail=100 rabbitmq

    # 2. Поднять
    docker compose -p payment-stage up -d rabbitmq

    # 3. Дождаться healthy (10–30 сек)
    sleep 20
    docker compose -p payment-stage ps rabbitmq

    # 4. Очереди на месте (durable, сообщения не потеряны)
    docker compose -p payment-stage exec -T rabbitmq \
      rabbitmqctl list_queues name messages

    # 5. Worker восстановился
    docker compose -p payment-stage ps worker
    # Ожидаемо: Up X seconds (healthy) — за ~15 сек

### Почему сообщения не теряются

`transfers`, `transfers.dlq`, `transfers.retry` объявлены с `durable=True`,
сообщения публикуются с `delivery_mode=2`. При рестарте RabbitMQ очереди
и сообщения сохраняются в `rabbitmq` volume. Unacked-сообщения возвращаются
в очередь после таймаута. Идемпотентность worker'а — проверка
`status != "PENDING"` в `consumer.py`: если перевод уже обработан,
worker пропускает повторную публикацию.

---

## 5. Ядовитые сообщения и DLQ

Сообщение уходит в `transfers.dlq` в двух случаях:

1. **PoisonMessage** — битый JSON / нет `transfer_id` / невалидный UUID →
   сразу в DLQ, без retry (повторять бессмысленно).
2. **MAX_RETRIES исчерпан** — 3 попытки с интервалом 5 сек через
   `transfers.retry` (TTL = 5000 ms) → в DLQ.

Метрики: `worker_poison_messages_total` (счётчик),
`worker_retries_total` (счётчик), `worker_dlq_size` (gauge).

### Посмотреть DLQ

    docker compose -p payment-stage exec -T rabbitmq \
      rabbitmqctl list_queues name messages | grep transfers

### Достать сообщение для разбора

    docker compose -p payment-stage exec -T rabbitmq sh -c \
      'rabbitmqadmin -u "$RABBITMQ_DEFAULT_USER" -p "$RABBITMQ_DEFAULT_PASS" \
       get queue=transfers.dlq count=1'

### Replay после ручного исправления payload

    docker compose -p payment-stage exec -T rabbitmq sh -c \
      'rabbitmqadmin -u "$RABBITMQ_DEFAULT_USER" -p "$RABBITMQ_DEFAULT_PASS" \
       publish exchange=amq.default routing_key=transfers \
       payload="{\"transfer_id\":\"<uuid>\",\"request_id\":\"replay-1\"}"'

### Purge DLQ (осторожно — сообщения пропадут)

    docker compose -p payment-stage exec -T rabbitmq sh -c \
      'rabbitmqadmin -u "$RABBITMQ_DEFAULT_USER" -p "$RABBITMQ_DEFAULT_PASS" \
       purge queue name=transfers.dlq'

Синтаксис `rabbitmqadmin`: `<команда> <тип> name=<имя>`. `purge queue=transfers.dlq`
даёт `ERROR: Type queue=transfers.dlq not recognised`.

### Алерты (Prometheus)

- `WorkerDLQGrowing` — `rate(worker_poison_messages_total[5m]) > 0` →
  сообщения уходят в DLQ прямо сейчас.
- `WorkerDLQNotEmpty` — `worker_dlq_size > 0` дольше 10 минут.

Оба требуют ручного разбора. См. `monitoring/rules.yml`.

---

## 6. Откат релиза

### Быстрый откат кода

    make rollback ENV=prod

Читает `deploy/.state/prod.previous_version`, пуллит образы этой версии
из GHCR, поднимает через `docker compose up -d --remove-orphans`.
**Не делает** `down`, идемпотентен.

Автооткат в CI: если `make smoke ENV=prod` падает после деплоя, workflow
вызывает `make rollback ENV=prod` автоматически и помечает job failed.

### Откат на произвольную версию

    make deploy ENV=prod APP_VERSION=<sha-старой-версии>

Это новый «деплой» старого SHA. Работает только если схема БД совместима
со старой версией (см. ниже).

### Что происходит со схемой БД при откате

**Схема НЕ откатывается автоматически.** Правила:

1. Миграции применяются ДО раскатки нового кода (`deploy.sh` шаг `[3/6]`).
2. Политика **expand → migrate → contract**:
   - релиз N: только `ADD COLUMN` / `CREATE TABLE`.
   - релиз N+1: новый код использует новые поля.
   - релиз N+2: `DROP` / `RENAME`, когда откат на N уже невозможен.
3. `migrate.sh` идемпотентен (таблица `schema_migrations`) +
   `pg_advisory_lock(728394)` — защита от параллельного запуска.
4. Если миграция была ломающей (`RENAME`/`DROP`) и нужен откат кода:
   - `make rollback` **сломает приложение** — не делать;
   - восстановить БД из бэкапа (§ 7), затем `make deploy ENV=prod APP_VERSION=<old-sha>`.

### Запрещено

- Править применённые миграции задним числом — только новая `NNN__fix.sql`.
- `RENAME` / `DROP` в одном релизе с фичами.
- `docker compose down -v` в скриптах деплоя.

---

## 7. Бэкап и восстановление БД

### Ручной бэкап

    make backup ENV=prod
    # → backups/payments-prod-20261108T120000Z.sql.gz

Проверяется на:
- файл непустой;
- валидный gzip (`gzip -t`);
- retention: старые (>7 дней, настраивается `RETENTION_DAYS`) удаляются.

### Автоматический (cron на хосте)

    # crontab -e
    0 3 * * * cd /path/to/repo && make backup ENV=prod >> /var/log/payments-backup.log 2>&1

Или через `scripts/backup-loop.sh prod` под systemd. Для тестового задания
cron на хосте достаточен — см. LIMITS § 3.4 (S3 не подключён).

### Проверенное восстановление (restore drill)

**Обязательно после каждого изменения схемы или инфраструктуры БД.**

    make restore-drill ENV=prod
    # или с конкретным файлом:
    make restore-drill ENV=prod FILE=backups/payments-prod-<...>.sql.gz

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
- Worker должен быть остановлен:
  `docker compose -p payment-prod stop worker`.
- **Код не откатывается.** После restore нужен
  `make deploy ENV=prod APP_VERSION=<sha-из-дампа>`, иначе новый код
  может быть несовместим со старой схемой.

### Что происходит со схемой после restore

Дамп включает `schema_migrations`. После restore таблица вернётся к
состоянию на момент бэкапа. При следующем `make deploy` шаг
`[3/6] Applying migrations` применит недостающие миграции.

**Осторожно**: если между дампом и restore были применены ломающие
миграции (`DROP`/`RENAME`), restore + повторная миграция могут
конфликтовать. См. `DECISIONS.md` § expand→contract и § 6 выше.

---

## 8. Секреты и Vault: что если секрета нет

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

И задать secret `VAULT_DEV_ROOT_TOKEN` с реальным значением. После этого
деплой без секрета падает на шаге `Write prod env from secrets`, не доходя
до `make deploy`.

### Что делать, если Vault перезапустился

Dev-режим Vault хранит данные **в памяти**. При рестарте контейнера все
секреты пропадают, но `runtime.env` остаётся (генерируется
`render-env.sh`), так что контейнеры продолжат работать на старом
`runtime.env`.

Восстановить:

    cd deploy
    docker compose -p payment-stage up -d vault
    ./vault/seed.sh stage
    ./vault/render-env.sh stage
    docker compose -p payment-stage up -d --force-recreate api worker

`make deploy` делает это автоматически (`deploy.sh` шаг `[1/6]`).

---

## 9. Проверено локально (drills)

Дата: 2026-11-08. Все сценарии прогнаны на `ENV=stage`,
`APP_VERSION=dev`.

### Восстановление БД (`make restore-drill`)

- `make backup ENV=stage` → валидный `.sql.gz` в `backups/`
- `make restore-drill ENV=stage` → `✅ RESTORE DRILL PASSED`
- `count(*)` source == `count(*)` restored
- `schema_migrations` присутствует

### Падение RabbitMQ (сценарий B)

1. `docker compose -p payment-stage stop rabbitmq` → rabbitmq Stopped.
2. `api /health/ready` → **503** (correct).
3. `docker compose ps worker` → `Restarting (1)` (restart loop,
   `pika.exceptions.AMQPConnectionError`).
4. `docker compose logs worker` → серия `AMQPConnectionError`.
5. `docker compose start rabbitmq` + 20 сек → worker **сам восстановился**:
   `Up 15 seconds (healthy)`.
6. `rabbitmqctl list_queues` → `transfers.dlq: 1` сохранилось (durable).

**Вывод**: worker без reconnection loop (см. LIMITS § 3.2), но
`restart: unless-stopped` компенсирует — контейнер перезапускается, пока
RabbitMQ не поднимется. Очереди durable, сообщения не теряются.

### Падение БД (сценарий A)

1. `docker compose -p payment-stage stop db` → db Stopped.
2. `api /health/ready` → **503** (`checks.db.ok = false`).
3. `api /health` → **200** (liveness жив, api не крашится).
4. `make smoke ENV=stage` → падает на `/health/ready`.
5. `docker compose start db` + 10 сек → `api /health/ready` → **200**.
6. `make smoke ENV=stage` → проходит.

**Вывод**: api не рестартится при падении БД (правильно — рестарт не
починит). Docker healthcheck у api смотрит на `/health` (liveness), не на
`/health/ready`. Ready-check ловит инцидент — smoke и автооткат сработают.