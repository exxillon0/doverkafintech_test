# DECISIONS — ключевые решения и почему

Каждая запись: **решение → почему → чем платим**. Ссылки на `RUNBOOK.md`
(§ N) и `LIMITS.md` (§ X.Y) — где применимо.

Про ИИ-инструменты — см. отдельный раздел в конце.

---

## 1. CD через `make deploy ENV=…`, а не YAML

Одна команда и локально, и в CI. Вся логика — в `deploy/*.sh`
(`deploy.sh`, `migrate.sh`, `rollback.sh`, `smoke.sh`), не в
`.github/workflows/*.yml`. CI вызывает `make deploy ENV=prod
APP_VERSION=$SHA` — ту же команду, что и разработчик локально.

**Почему:** воспроизводимость. Если YAML и скрипты — разные источники
правды, CI расходится с локальным запуском. Сейчас — один источник:
`.github/workflows` только оркестрирует `make`, а логика в shell-скриптах,
которые работают без GitHub Actions.

**Чем платим:** сложнее «прочитать pipeline в одном файле» — нужно
открыть Makefile + 4 скрипта. Компенсируется README и этой записью.

Проверено: `make deploy ENV=stage APP_VERSION=dev` локально даёт тот же
результат, что CI `cd`-джоба.

---

## 2. Миграции ДО раскатки, политика expand → migrate → contract

`deploy.sh` применяет миграции шагом `[3/6]` **до** `docker compose up`
нового кода (`[5/6]`). `migrate.sh` идемпотентен: ведёт таблицу
`schema_migrations`, уже применённые версии пропускает. Защита от
параллельного запуска — `pg_advisory_lock(728394)`.

**Политика изменения схемы:**

- релиз N: только `ADD COLUMN` / `CREATE TABLE` (аддитивно, старый код
  продолжает работать);
- релиз N+1: новый код использует новые поля;
- релиз N+2 (через несколько дней): `DROP` / `RENAME`, когда откат на N
  уже невозможен.

**Почему:** схема **не откатывается автоматически** (`rollback.sh`
переключает только `APP_VERSION` образов). Если миграция ломающая
(`RENAME`/`DROP`) и нужен откат кода — старая версия несовместима с новой
схемой, `make rollback` сломает приложение. Expand→contract делает откат
безопасным для N и N+1.

**Чем платим:** `DROP`/`RENAME` откладываются на 1–2 релиза, схема
«обрастает» старыми колонками. Для финтеха это приемлемо — данные
переводов важнее чистоты схемы. Подробная процедура — `RUNBOOK.md` § 6.

`pg_advisory_lock` — превентивно: при одной реплике api/worker миграции
не пересекаются, но при масштабировании lock обязателен, чтобы `migrate.sh`
не запустился параллельно из двух контейнеров.

---

## 3. Liveness vs Readiness: раздельные endpoint'ы

`/health` = liveness (процесс жив). `/health/ready` = readiness (БД +
RabbitMQ доступны). `/health/db` и `/health/rabbit` — детальные проверки
для диагностики (`RUNBOOK.md` § 2).

**Почему:**

- **Docker healthcheck смотрит на `/health` (liveness).** Падение БД не
  должно приводить к рестарту api — рестарт не починит внешнюю
  зависимость, только увеличит downtime.
- **Smoke после деплоя смотрит на `/health/ready`.** Если api поднялся,
  но не видит БД — деплой считается проваленным, срабатывает автооткат.
- **`api_dependency_up{dependency="db|rabbit"}` gauge** — алерт
  `ApiDependencyDown` в `monitoring/rules.yml` без парсинга логов.

**Реализация:** sync-проверки (psycopg, pika) унесены в
`asyncio.to_thread`, чтобы не блокировать event loop Starlette.
Timeout'ы — 3 сек (`connect_timeout` в dsn, `socket_timeout` в pika) —
иначе `/health/ready` мог бы висеть.

**Чем платим:** три эндпоинта вместо одного, чуть больше кода и тестов.
Компенсируется понятной диагностикой (`/health/db` vs `/health/rabbit`
сразу показывает, что сломано).

Проверено: `RUNBOOK.md` § 9 (drills) — при `stop db` api `/health` = 200,
`/health/ready` = 503.

---

## 4. DLQ через republish, а не `nack(requeue=False)`

При ошибке сообщение **перепубликуется** в `transfers.retry` с заголовком
`x-retry-count+1`, а оригинал подтверждается (`basic_ack`). Retry-очередь
имеет `x-message-ttl=5000` и `x-dead-letter-exchange` обратно в `transfers`
— сообщение возвращается через 5 сек. После `MAX_RETRIES=3` — в
`transfers.dlq` через `transfers.dlx` (fanout). `PoisonMessage` (битый
payload) — сразу в DLQ, без retry.

**Почему не `nack(requeue=False)`:**

- `nack` не даёт **изменить заголовки** — счётчик попыток некуда положить.
  Без счётчика нельзя ограничить retry.
- Retry-очередь с TTL даёт **паузу между попытками** (не грузит CPU
  мгновенным retry) — важно для транзиентных ошибок (pika timeout, БД
  временно недоступна).
- `PoisonMessage` не retry'ится: битый JSON не станет валидным при
  повторе, только задержит очередь.

**Чем платим:** больше топологии (3 очереди + 1 exchange), сообщение
проходит 2 publish на retry. Компенсируется: одно «ядовитое» сообщение
без DLQ останавливает все переводы — это несоизмеримо хуже.

Метрики `worker_poison_messages_total` + `worker_dlq_size` дают алерт
`WorkerDLQGrowing` (`monitoring/rules.yml`). Процедура разбора —
`RUNBOOK.md` § 5.

---

## 5. `depends_on: service_healthy` защищает только старт

В `docker-compose.yml` у `api` и `worker`:

    depends_on:
      db:       { condition: service_healthy }
      rabbitmq: { condition: service_healthy }

Это гарантирует **порядок старта**, но **не рантайм**. Если БД упадёт
через 10 минут после старта api — api узнает только при следующем
`psycopg.connect()` → 500 клиенту. Compose не перезапустит api и не
остановит reverse-proxy.

**Почему это правильно:**

- Рестарт api не починит БД. Перезапускать рабочий процесс из-за сбоя
  внешней зависимости — антипаттерн.
- Слежение за состоянием — задача **readiness** (`/health/ready` → 503),
  а не рестарта (см. § 3).

**Что не реализовано (для реального прода):** nginx
`proxy_next_upstream` + `max_fails` — чтобы reverse-proxy убирал
api-инстанс при 503; разделение liveness/readiness в k8s
(`readinessProbe`). Сейчас одна реплика — не актуально (см. `LIMITS.md`
§ 5.2).

---

## 6. Restart policies: `unless-stopped` для всех, без backoff

Все сервисы в compose: `restart: unless-stopped`. Docker перезапускает
контейнер при exit ≠ 0, не перезапускает при exit 0 или `docker stop`.

**Trade-off:**

| Политика | Плюсы | Минусы |
|---|---|---|
| `unless-stopped` (текущая) | Самовосстановление после краша | Нет backoff → restart loop |
| `on-failure:N` | Ограничивает retry loop | При исчерпании — контейнер стоит, нужен ручной старт |
| `no` | Прозрачность, алерт при exit | Нет самовосстановления |

**Почему `unless-stopped`:** для одной машины с демонстрационным стеком —
адекватный default. Проверено: при `stop rabbitmq` worker уходит в
`Restarting (1)` с `AMQPConnectionError`, при `start rabbitmq` —
восстанавливается за ~15 сек автоматически. Очереди durable, сообщения
не теряются.

**Что не реализовано:** worker без reconnection loop (см. `LIMITS.md`
§ 3.2). Переподключение через рестарт контейнера работает, но неэлегантно:
~1 сек loop, засоряет логи. Для реального прода — `try/except
AMQPConnectionError` вокруг `start_consuming()` + `time.sleep(2**attempt)`,
либо k8s `CrashLoopBackOff`.

Для нескольких хостов — k8s `restartPolicy: Always` + `backoffLimit`,
либо compose + systemd `RestartSec=10s`.

---

## 7. Vault: ephemeral dev-token по умолчанию, реальный секрет — opt-in

CI по умолчанию генерирует ephemeral `VAULT_DEV_ROOT_TOKEN`, если секрет
не задан в GitHub Secrets (`ALLOW_EPHEMERAL_VAULT_TOKEN=true` — default).

**Почему:** ТЗ требует, чтобы проект разворачивался «с нуля по README» без
настройки — иначе ревьюер упадёт на шаге `[1/6] Vault up`.

**Как включить «настоящий прод-режим»:** Settings → Variables →
`ALLOW_EPHEMERAL_VAULT_TOKEN=false` + secret `VAULT_DEV_ROOT_TOKEN` с
реальным значением. Тогда деплой без секрета падает на шаге
`Write prod env from secrets`, не доходя до `make deploy`.

**Чем платим:** ephemeral-токен **не безопасен** — это dev-режим Vault
(данные в памяти, аутентификации нет). Но default разумный для тестового,
явно задокументирован, и для прода переключается одной переменной.

Полная матрица «сценарий → поведение» — `RUNBOOK.md` § 8. Ограничения
dev-режима — `LIMITS.md` § 2.1.

---

## 8. Trivy: `CRITICAL` блокирует, `HIGH` — нет

`trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed` — gate,
падает на эксплуатируемых CRITICAL без патча. `trivy image --exit-code 0
--severity HIGH` — лог, не блокирует.

**Почему:** базовые образы `python:3.11-slim` и `postgres:13.14` содержат
`HIGH` CVE, часть — без фикса. `--exit-code 1` на `HIGH` остановил бы
пайплайн «навсегда» без возможности починить. `--ignore-unfixed` на
`CRITICAL` — реальный gate: если CRITICAL **с фиксом** — пайплайн
падает, инженер обновляет базовый образ.

**Чем платим:** `HIGH`-уязвимости могут уехать в прод. Компенсируется:
ревью порогов — раз в месяц, либо при появлении патча; `.trivyignore`
с обоснованием для каждой принятой CVE (сейчас не заведён, см.
`LIMITS.md` § 1.3).

---

## Об ИИ-инструментах

**Что использовал:** Claude (через веб-интерфейс) — для дизайна CI/CD
пайплайна, DLQ-механики, restore drill; GitHub Copilot — для автодополнения
в `consumer.py` и `main.py`; ChatGPT — для ревью RUNBOOK.

**Где ИИ ошибался и как заметил:**

1. **Claude предлагал `docker compose down` в `deploy.sh`** — это
   не идемпотентно (сносит контейнеры каждый деплой, downtime). Заметил
   по логу `Container ... Recreated` на каждом прогоне CI → заменил на
   `up -d --remove-orphans`.

2. **Claude предлагал `curl http://localhost:8000/health` в smoke** — но
   api не публикует порт 8000 наружу (только reverse-proxy на 8080).
   Заметил по логу `curl: (7) Failed to connect` в smoke → заменил на
   `docker compose exec api python -c "urllib..."`.

3. **Claude добавил `import functools` в середину `main.py`** без
   использования → `ruff I001` + `F401` на CI. Заметил по логу lint,
   перенёс в шапку + применил `@functools.lru_cache`.

4. **Claude забыл `httpx` в `Install dependencies`** → `RuntimeError:
   testclient requires httpx`. Заметил по логу `make test`, добавил в
   pip-строку.

5. **Copilot «починил» CD, добавив retry для Vault** — но это было
   корректное решение (Vault иногда стартует дольше `--wait`). Проверил
   через `docker compose logs vault` + повторный прогон CI — прошло
   стабильно, оставил.

6. **Claude предлагал `basic_nack(requeue=True)`** в первой итерации
   `consumer.py` — это привело бы к бесконечному retry для «ядовитых»
   сообщений. Заметил при дизайне DLQ: `requeue=True` на любое исключение
   = вечный цикл. Заменил на `republish` в retry-очередь + лимит.

**Что делал сам без ИИ:** интеграция (сборка compose, seed.sh,
render-env.sh), локальные прогоны drills, отладка конфликтов портов,
финальная вычитка документации. ИИ — ускоритель на этапе «набросать
вариант», не замена пониманию.