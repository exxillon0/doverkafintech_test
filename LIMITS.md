# LIMITS.md — что не сделано и почему

Честно фиксирует границы решения на момент сдачи. ТЗ прямо говорит:
«воспроизводимый Level 1–2 с честным LIMITS.md лучше недоделанного
"всё сразу"». Структура: **Что → Почему → Влияние → Что нужно**.

Что сделано — см. § 7 в конце. Приоритеты — § 8.

---

## 1. Доставка (Level 2)

### 1.1. Stage-джоба в CI отсутствует

- **Что**: CD деплоит только `prod` (push в `main`). `make deploy ENV=stage`
  работает локально, но автоматического прогона на stage из CI нет.
- **Почему**: одно «настоящее» окружение; stage задуман как локальный
  demo-контур для проверки пайплайна. Stage-host в рамках 72 часов не
  поднимался.
- **Влияние**: нельзя показать «задеплоили на stage → e2e → промоут на
  prod». Ревьюер воспроизводит stage локально:
  `make deploy ENV=stage APP_VERSION=dev`.
- **Что нужно**: отдельный runner/host, `workflow_dispatch` или job
  `cd-stage` с `concurrency: deploy-stage`, GitHub Environment `stage`
  с required reviewers перед промоушном на prod.

### 1.2. Автооткат не покрыт автотестом

- **Что**: механика автоотката (`rollback.sh` + `continue-on-error` в
  `cd`) проверена вручную (сломали smoke → CI откатился). Автотеста,
  который прогоняет сценарий на каждый PR, нет.
- **Почему**: тест автоотката требует поднятого окружения и «плохой»
  версии образа; на одном GitHub-раннере это дорого и хрупко.
- **Влияние**: регрессия в `rollback.sh` может остаться незамеченной до
  реального инцидента.
- **Что нужно**: «chaos»-прогон по расписанию (`schedule: cron`) на
  выделенном stage; либо integration-тест с docker-in-docker.

### 1.3. Trivy блокирует только `CRITICAL`

- **Что**: `--severity CRITICAL --exit-code 1` — gate. `HIGH` — только
  лог (`--exit-code 0`).
- **Почему**: базовые `python:3.11-slim` и `postgres:13.14` содержат
  `HIGH` CVE, часть — без фикса. Блокировка на `HIGH` остановила бы
  пайплайн без возможности починить.
- **Влияние**: `HIGH`-уязвимости могут уехать в прод.
- **Что нужно**: SLA на триаж `HIGH` (раз в неделю), `.trivyignore` с
  обоснованием по каждой CVE, переход на `--exit-code 1` для `HIGH`
  после апгрейда базовых образов.

### 1.4. Нет проверки подписи образов (cosign / sigstore)

- **Что**: образы пушатся в GHCR, но не подписываются. `cd` доверяет
  registry по факту `docker pull`.
- **Почему**: не входит в Level 2, добавляет заметную сложность
  (keyless OIDC, Fulcio/Rekor).
- **Влияние**: компрометация GHCR-аккаунта → компрометация прода.
- **Что нужно**: `cosign sign` в `ci`, `cosign verify` в `cd`, политика
  «deploy only signed images».

---

## 2. Секреты (Level 3)

### 2.1. Vault работает в dev-режиме

- **Что**: `hashicorp/vault:1.15.4` запускается как `vault server -dev`.
  Токен (`VAULT_DEV_ROOT_TOKEN`) — dev-заглушка, данные в памяти, при
  рестарте контейнера теряются, аутентификации нет.
- **Почему**: ТЗ прямо говорит «Vault (dev-режим)». Prod-режим с
  инициализацией, unseal-keys, AppRole — вне рамок.
- **Влияние**: после рестарта Vault секреты нужно пересидить (`deploy.sh`
  § `[1/6]` делает это автоматически). Для реального прода небезопасно.
- **Что нужно**: `vault server -config=...` с file-storage/Raft, unseal
  через KMS/HSM, AppRole для api/worker, ротация токенов.

### 2.2. Секреты для `prod` в CI — opt-in через переменную

- **Что**: `cd`-джоба берёт `VAULT_DEV_ROOT_TOKEN` из GitHub Secrets.
  Если секрет не задан и `ALLOW_EPHEMERAL_VAULT_TOKEN=true` (default) —
  генерируется эфемерный dev-токен + `::warning::`. Если `false` —
  пайплайн падает на шаге `Write prod env from secrets`.
- **Почему**: ТЗ требует «разворачивается с нуля по README без настройки»
  — иначе ревьюер упадёт на первом шаге. Компромисс: ephemeral — для
  demo, реальный секрет — для прода, переключается переменной.
- **Влияние**: по факту наличия секрета нельзя отличить «настоящий
  прод» от «демо» — только по явному `ALLOW_EPHEMERAL_VAULT_TOKEN=false`.
- **Что нужно**: для прода — required secret + `ALLOW_EPHEMERAL_VAULT_TOKEN=false`
  в настройках (сейчас default `true`).

### 2.3. Ротация секретов не автоматизирована

- **Что**: `vault/seed.sh` записывает секреты один раз. Ротации
  (`POSTGRES_PASSWORD`, `RABBITMQ_PASSWORD`, `PROVIDER_API_KEY`) по
  расписанию нет.
- **Почему**: требует координации с перезапуском контейнеров.
- **Влияние**: скомпрометированный секрет живёт до ручной ротации.
- **Что нужно**: Vault dynamic secrets (database secrets engine для
  Postgres), либо cron с `vault write` + `docker compose up -d --force-recreate`.

---

## 3. Надёжность (Level 3)

### 3.1. Worker без reconnection loop, restart loop без backoff

- **Что**: `worker` использует `pika.BlockingConnection` + `start_consuming()`.
  При падении RabbitMQ — `pika.exceptions.AMQPConnectionError` → процесс
  завершается → `restart: unless-stopped` перезапускает контейнер → снова
  падает. Restart loop с интервалом ~1 сек.
- **Почему**: reconnection loop с экспоненциальным backoff — это
  `try/except` вокруг `start_consuming()` + `time.sleep(2**attempt)`.
  Для одной реплики `unless-stopped` достаточно: **проверено**
  (`RUNBOOK.md` § 9), что при `start rabbitmq` worker восстанавливается
  за ~15 сек автоматически.
- **Влияние**: пока RabbitMQ лежит — worker долбит его каждую секунду,
  засоряя логи. Очереди durable, сообщения не теряются. api
  `/health/ready` → 503, smoke и автооткат срабатывают.
- **Что нужно**: reconnection loop в `consumer.py`:

      attempt = 0
      while True:
          try:
              connection = pika.BlockingConnection(params)
              channel = connection.channel()
              _declare_topology(channel)
              channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
              channel.start_consuming()
          except pika.exceptions.AMQPConnectionError:
              attempt += 1
              wait = min(2 ** attempt, 60)
              log.warning("reconnect in %ds", wait)
              time.sleep(wait)

  Либо k8s с `CrashLoopBackOff` — backoff делает оркестратор.

### 3.2. Бэкап БД: локально на хосте, без offsite

- **Что**: `scripts/backup.sh` делает `pg_dump` → gzip → `backups/` на
  том же хосте. Retention 7 дней (`RETENTION_DAYS`). Restore drill есть
  (`make restore-drill`, проверен — см. `RUNBOOK.md` § 9).
- **Почему**: S3/MinIO требует кредов, бакета, IAM. Для тестового задания
  — over-engineering; локальный диск показывает, что механика работает.
- **Влияние**: при потере хоста бэкапы тоже теряются. Для прод-финтеха
  недопустимо.
- **Что нужно**: `aws s3 cp` в `backup.sh`, отдельный bucket с
  версионированием, lifecycle policy, шифрование (SSE-KMS). Restore
  drill — из S3, не с локали.

### 3.3. Cron для бэкапов — на хосте, не в контейнере

- **Что**: автоматический бэкап — через `crontab` на хосте или
  `scripts/backup-loop.sh` под systemd. В compose отдельного cron-сервиса
  нет.
- **Почему**: одна машина, cron на хосте достаточен. Контейнерный cron
  (Ofelia, `docker-crontab`) — лишняя зависимость для demo.
- **Влияние**: если хост перезагрузился — cron на месте, но при
  переезде на несколько хостов нужно централизованное расписание.
- **Что нужно**: `Ofelia` или sidecar-cron в compose, либо managed cron
  (AWS EventBridge, GCP Cloud Scheduler).

---

## 4. Наблюдаемость (Level 3/4)

### 4.1. Бизнес-метрик нет

- **Что**: `prometheus` собирает инфраструктурные метрики (`api_requests_total`,
  `worker_messages_total`, `api_dependency_up`, `worker_dlq_size`).
  RED-метрики для api (rate/errors/duration) частично покрыты
  `api_requests_total`. Бизнес-метрик (переводы по статусам, возраст
  самого старого `PENDING`) — нет.
- **Почему**: Level 4 (бонус), требует инструментирования бизнес-логики.
- **Влияние**: дашборд «платежи работают?» за 10 секунд не собирается.
- **Что нужно**: `prometheus_client` counter
  `transfers_total{status="PENDING|COMPLETED|FAILED"}`, gauge
  `transfer_oldest_pending_age_seconds`, Grafana-дашборд.

### 4.2. Alert rules есть, alertmanager не настроен

- **Что**: `monitoring/rules.yml` содержит 4 алерта (`WorkerDLQGrowing`,
  `WorkerDLQNotEmpty`, `ApiDependencyDown`, `WorkerSilent`). Prometheus
  их вычисляет, но `alertmanager` в compose нет — алерты видны только
  в `/api/v1/alerts`, наружу не уходят.
- **Почему**: alertmanager + каналы (Slack/Telegram/email) — отдельная
  интеграция с внешними сервисами и секретами. Для demo не критично.
- **Влияние**: инциденты не приходят «сами» — нужно открывать Prometheus
  UI. `WorkerSilent` не сработает, если упал сам Prometheus.
- **Что нужно**: `prom/alertmanager` в compose, `alertmanager.yml` с
  receivers, каналы в `RUNBOOK.md`. Плюс мета-мониторинг (§ 4.3).

### 4.3. Мета-мониторинг отсутствует

- **Что**: если `prometheus` упал — никто об этом не узнает. «Молчание
  сервиса ≠ всё хорошо» — не реализовано.
- **Почему**: требует внешнего watchdog (healthchecks.io / dead-man-switch).
- **Влияние**: тихий отказ мониторинга = слепой прод.
- **Что нужно**: watchdog на cron-пуш из prometheus; алерт «нет метрик
  5 минут» через независимый канал.

### 4.4. Логи не централизованы

- **Что**: `json-file` с `max-size: 10m`, `max-file: 3` на контейнер.
  Логи структурированы (JSON + `request_id` end-to-end, см. § 7),
  но централизованного сбора (Loki/ELK) нет.
- **Почему**: достаточно для одной машины. Loki/fluent-bit — лишняя
  инфраструктура для demo.
- **Влияние**: при переезде на несколько хостов логи не собрать в одном
  месте. Для одной машины — `docker compose logs` работает.
- **Что нужно**: `promtail` → `loki`, либо `fluent-bit` → `elasticsearch`;
  Grafana Explore для поиска по `request_id`.

---

## 5. Инфраструктура и воспроизводимость

### 5.1. Всё на одном Docker-host

- **Что**: `docker-compose.yml` поднимает 8 сервисов на одной машине.
  Нет разделения control-plane / data-plane, нет anti-affinity.
- **Почему**: рамки задания — «Docker Compose v2 на чистой машине».
- **Влияние**: падение хоста = падение всего стека. Нет горизонтального
  масштабирования.
- **Что нужно**: k8s (или Nomad), либо разделение «db/rabbitmq —
  отдельный хост».

### 5.2. Одна реплика каждого сервиса

- **Что**: `api:1`, `worker:1`, `mock-provider:1`.
- **Почему**: `pg_advisory_lock` в `migrate.sh` — превентивный, на случай
  масштабирования; реально реплик всегда одна.
- **Влияние**: нет zero-downtime обновлений — `docker compose up -d`
  пересоздаёт контейнер, короткий downtime есть.
- **Что нужно**: `deploy: replicas: 2` для api (за reverse-proxy),
  worker — конкурентные consumer'ы с `prefetch_count`, rolling update
  через `docker compose up -d --no-deps --scale`.

### 5.3. Rollback БД — только expand→contract, без `migrate down`

- **Что**: `rollback.sh` откатывает **код**, но не схему. Для ломающих
  миграций (`RENAME`, `DROP COLUMN`) откат кода сломает приложение;
  единственный путь — restore из бэкапа (см. `RUNBOOK.md` § 6 и § 7).
- **Почему**: осознанное решение (см. `DECISIONS.md` § 2), классика
  expand→contract. Полноценный `migrate down` в рамках 72 часов не
  писался.
- **Влияние**: если нарушить правило «RENAME/DROP — отдельным релизом»,
  откат станет ручным и болезненным.
- **Что нужно**: `NNN__*.down.sql` для каждой миграции + `migrate.sh
  --down N`, **плюс** автоматический бэкап перед каждой миграцией.

### 5.4. Нет e2e-теста «положил перевод → он дошёл до COMPLETED»

- **Что**: `smoke.sh` проверяет `/health/ready` и `pg_isready`. Сквозного
  сценария (POST /transfers → worker обработал → статус COMPLETED) нет.
- **Почему**: требует mock-provider + реальной очереди + ожидания;
  в smoke замедлило бы деплой.
- **Влияние**: smoke может быть зелёным, а бизнес-логика сломана.
- **Что нужно**: `make e2e` с `curl POST /transfers` + polling
  `GET /transfers/{id}` до `COMPLETED`/`FAILED` с таймаутом 30 сек.

---

## 6. Процесс

### 6.1. Один разработчик, 72 часа

- **Что**: нет code review, обязательных approvals, branch protection.
  `main` пушится напрямую.
- **Почему**: соло-разработка в рамках тестового.
- **Влияние**: регрессии ловятся CI, но не ревью.
- **Что нужно**: branch protection (required PR + required checks),
  `CODEOWNERS`, минимум 1 approve.

### 6.2. Нет staging→prod promotion gate

- **Что**: push в `main` сразу едет в прод. Нет «approve to prod».
- **Почему**: одно окружение (см. § 1.1).
- **Влияние**: любой баг в `main` = баг в проде через 2 минуты.
- **Что нужно**: GitHub Environments (`stage` → `prod`) с required
  reviewers; `workflow_dispatch` с параметром `environment`.

### 6.3. `docker compose down -v` не запрещён на уровне tooling

- **Что**: в скриптах деплоя `down -v` нет (осознанно), но ничто не
  мешает выполнить его руками.
- **Почему**: shell — есть shell.
- **Влияние**: случайный `down -v` снесёт `pgdata`.
- **Что нужно**: alias/wrapper `docker` → `safe-docker` (отказывается
  от `down -v` без `--i-know-what-i-do`), либо managed DB (RDS), где
  volume не в docker.

---

## 7. Что сделано

Чтобы не сложилось впечатление «всё плохо»:

**Level 1 (гигиена):**
- Pinning версий образов (`python:3.11-slim`, `postgres:13.14`,
  `rabbitmq:3.9.29-management`, `nginx:1.25.5-alpine`,
  `prom/prometheus:v2.50.1`).
- Multi-stage builds (api, worker, mock-provider).
- Non-root (`appuser`, uid 1000).
- `.dockerignore` (tests, `.env`, `.git`, `__pycache__`).
- Healthcheck'и (реальные: `pg_isready`, `rabbitmq-diagnostics`,
  `python -c urllib...` вместо `curl` в slim-образе).
- `depends_on: condition: service_healthy` (старт в правильном порядке).
- Секретов нет в образах — `runtime.env` генерируется из Vault.

**Level 2 (доставка):**
- CI: lint (`ruff`), test (`pytest` + `python -m pytest` для
  `import app`), build (`docker compose build`), scan (Trivy,
  `CRITICAL` — gate), тег образа по SHA (`APP_VERSION=$SHA`).
- CD: `make deploy ENV=…` — одна команда и локально, и в CI; идемпотентно
  (`up -d --remove-orphans`, без `down`).
- Миграции **до** раскатки (`deploy.sh` § `[3/6]`), `pg_advisory_lock`.
- Smoke после деплоя (`/health/ready` + `pg_isready` + worker running).
- Автооткат (`continue-on-error` на smoke → `make rollback`).
- Ручной откат (`make rollback ENV=…`).
- `RUNBOOK.md` § 6 — «Что происходит со схемой БД при откате».
- Доказательство CI:
  https://github.com/exxillon0/doverkafintech_test/actions/runs/42389989594

**Level 3 (секреты и надёжность):**
- `request_id` end-to-end: middleware в api → `X-Request-ID` в ответе →
  payload в RabbitMQ → `contextvar` в worker → JSON-логи с полем
  `request_id` (см. `DECISIONS.md` § 3, `RUNBOOK.md` § 5).
- Structured logging (JSON) в api и worker, `pika`/`urllib3`/
  `prometheus_client` приглушены до `INFO`.
- `/health`, `/health/ready`, `/health/db`, `/health/rabbit` +
  `api_dependency_up{dependency}` gauge.
- DLQ через republish: `transfers.dlx` (fanout) → `transfers.dlq`,
  retry-очередь с TTL 5с, `MAX_RETRIES=3`, метрики
  `worker_poison_messages_total` / `worker_retries_total` /
  `worker_dlq_size` (см. `DECISIONS.md` § 4, `RUNBOOK.md` § 5).
- Алерты в `monitoring/rules.yml` (`WorkerDLQGrowing`,
  `WorkerDLQNotEmpty`, `ApiDependencyDown`, `WorkerSilent`) — вычисляются
  Prometheus, alertmanager не настроен (§ 4.2).
- Бэкап БД: `scripts/backup.sh` (`pg_dump` + gzip + retention),
  `scripts/restore.sh` (destructive), `scripts/restore-drill.sh`
  (**проверенное** восстановление в temp БД со сравнением `count(*)`
  и `schema_migrations`).
- Поведение при падении БД/RabbitMQ — проверено и задокументировано
  (`RUNBOOK.md` § 9).
- Vault: `ALLOW_EPHEMERAL_VAULT_TOKEN=false` для реального прода,
  `ALLOW_DEV_VAULT=1` для локального demo (см. `DECISIONS.md` § 7).

**Документация:**
`README`, `ARCHITECTURE`, `DECISIONS`, `ASSUMPTIONS`, `RUNBOOK`, `LIMITS`
(этот файл), `Makefile` + `scripts/`.

---

## 8. Приоритеты, если будет ещё время

1. **`alertmanager` + каналы** (§ 4.2) — правила уже есть, осталось
   «доставить» их до людей. Самый дешёвый шаг из оставшихся.
2. **`make e2e`** (§ 5.4) — smoke ловит инфраструктуру, но не бизнес-логику.
   Один `curl POST /transfers` + polling до `COMPLETED` закроет дыру.
3. **Stage-джоба в CI + GitHub Environment** (§ 1.1, § 6.2) — формально
   закрывает «stage и prod без копипасты» из Level 2.
4. **S3 для бэкапов** (§ 3.2) — для прода критично, но требует внешнего
   сервиса (MinIO в compose — вариант).
5. **Reconnection loop в worker** (§ 3.1) — эстетика + меньше шума в
   логах, не блокер.
6. **Бизнес-метрики + дашборд** (§ 4.1) — Level 4, если останется время.