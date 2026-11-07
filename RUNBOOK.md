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