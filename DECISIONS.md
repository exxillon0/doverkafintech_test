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


## DLQ через republish, а не nack(requeue=False)

При ошибке сообщение **перепубликуется** в retry-очередь с `x-retry-count+1`,
а оригинал подтверждается (`basic_ack`). Причины:

- `basic_nack(requeue=False)` не даёт изменить заголовки — счётчик попыток
  некуда положить.
- Retry-очередь с `x-message-ttl=5000` даёт паузу между попытками (не
  грузит CPU мгновенным retry) и возвращает сообщение в основную через
  `x-dead-letter-exchange`.
- После `MAX_RETRIES=3` — в DLQ через `transfers.dlx` (fanout).

`PoisonMessage` (битый payload) — сразу в DLQ, без retry: повторять
бессмысленно, только задержит очередь.

Метрики `worker_poison_messages_total` + `worker_dlq_size` дают алерт
`WorkerDLQGrowing` — самое важное для финтеха: одно «ядовитое» сообщение
без DLQ останавливает все переводы.


## Vault: ephemeral dev-token по умолчанию, реальный секрет — opt-in

CI по умолчанию генерирует ephemeral `VAULT_DEV_ROOT_TOKEN`, если секрет
не задан в GitHub Secrets. Причина: ТЗ требует, чтобы проект
разворачивался «с нуля по README» без настройки — иначе ревьюер упадёт
на шаге 1.

Для реального прода — `ALLOW_EPHEMERAL_VAULT_TOKEN=false` в
Settings→Variables. Тогда деплой без секрета падает на шаге
`Write prod env from secrets`, не доходя до `make deploy`.

Компромисс: ephemeral-токен **не безопасен** (это dev-режим Vault), но
это явно задокументировано и не является default для прода.