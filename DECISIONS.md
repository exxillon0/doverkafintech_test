## CD через `make deploy ENV=…`

Одна команда и локально, и в CI. Логика в `deploy/deploy.sh`,
`migrate.sh`, `rollback.sh`, `smoke.sh` — не в YAML. Это значит, что
разработчик может воспроизвести деплой на своей машине без GitHub Actions,
а на защите мы можем показать «сломали — откатились» локально.

## Миграции ДО раскатки, expand→contract

`deploy.sh` применяет миграции до `docker compose up` нового кода.
`migrate.sh` использует `pg_advisory_lock`, чтобы при нескольких репликах
миграция не запустилась параллельно. Схема БД **не откатывается
автоматически** (см. RUNBOOK): откат кода безопасен только для
аддитивных миграций. Политика — expand → migrate → contract.

## Trivy: `CRITICAL` блокирует, `HIGH` — нет

`--exit-code 1 --severity CRITICAL --ignore-unfixed` — gate, падает на
эксплуатируемых CRITICAL. `HIGH` — лог, не блокирует, чтобы не вставать
из-за неисправимых уязвимостей в базовом образе Python/Postgres. Ревизия
порогов — раз в месяц, либо при появлении патча.


## Liveness vs Readiness: раздельные endpoint'ы

`/health` = liveness (процесс жив). `/health/ready` = readiness (БД +
RabbitMQ доступны). Причины:

- Docker healthcheck смотрит на liveness. Падение БД не должно приводить
  к рестарту api — рестарт не починит внешнюю зависимость, только
  увеличит downtime.
- Smoke после деплоя смотрит на readiness. Если api поднялся, но не видит
  БД — деплой считается проваленным, срабатывает автооткат.
- `api_dependency_up{dependency}` gauge позволяет алертить на «api видит
  БД?» без парсинга логов (алерт — Level 4, TODO).

Sync-проверки (psycopg, pika) унесены в `asyncio.to_thread`, чтобы не
блокировать event loop Starlette. Timeout'ы ограничены 3с через
`connect_timeout` в dsn и `socket_timeout` в pika — иначе `/health/ready`
мог бы висеть.