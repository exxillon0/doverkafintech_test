import asyncio
import logging
import uuid

import psycopg
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import broker
from .config import load_settings
from .logging_setup import RequestIDMiddleware, request_id_var, setup_logging
from .validation import InvalidTransfer, parse_transfer, to_minor

import functools

def _settings():
    return load_settings()

class _LazySettings:
    def __getattr__(self, name):
        return getattr(_settings(), name)

settings = _LazySettings()
setup_logging()
log = logging.getLogger("api")
log.info("starting", extra={"db_host": settings.db_host, "log_level": settings.log_level})

REQUESTS = Counter("api_requests_total", "HTTP requests", ["method", "path", "status"])
DEP_UP = Gauge("api_dependency_up", "1=ok, 0=down", ["dependency"])


def count(request, response):
    REQUESTS.labels(request.method, request.url.path.split("/")[1], response.status_code).inc()
    return response


# ---------- health ----------

async def health(request):
    """Liveness. Процесс жив — 200, даже если зависимости лежат.
    Рестарт контейнера не лечит упавшую БД, поэтому здесь только процесс."""
    return JSONResponse({"status": "ok"})


def _check_db_sync() -> None:
    # dsn содержит connect_timeout=3 (см. config.py) — не зависнем
    with psycopg.connect(settings.dsn) as conn:
        conn.execute("SELECT 1")


def _check_rabbit_sync() -> None:
    import pika
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    params = pika.ConnectionParameters(
        host=settings.rabbitmq_host,
        credentials=credentials,
        socket_timeout=3,
        blocked_connection_timeout=3,
    )
    connection = pika.BlockingConnection(params)
    try:
        connection.channel().queue_declare(queue="transfers", durable=True, passive=True)
    finally:
        connection.close()


async def _check_dep(name: str, fn) -> tuple[bool, str]:
    try:
        await asyncio.to_thread(fn)  # psycopg/pika — sync, уносим в thread
        DEP_UP.labels(name).set(1)
        return True, "ok"
    except Exception as exc:
        DEP_UP.labels(name).set(0)
        log.warning("dependency check failed", extra={"dependency": name, "error": str(exc)})
        return False, str(exc)


async def health_db(request):
    ok, detail = await _check_dep("db", _check_db_sync)
    return JSONResponse(
        {"status": "ok" if ok else "fail", "detail": detail},
        status_code=200 if ok else 503,
    )


async def health_rabbit(request):
    ok, detail = await _check_dep("rabbit", _check_rabbit_sync)
    return JSONResponse(
        {"status": "ok" if ok else "fail", "detail": detail},
        status_code=200 if ok else 503,
    )


async def health_ready(request):
    """Readiness: 200 только если ВСЕ зависимости доступны."""
    results = {
        "db": await _check_dep("db", _check_db_sync),
        "rabbit": await _check_dep("rabbit", _check_rabbit_sync),
    }
    ready = all(ok for ok, _ in results.values())
    return JSONResponse(
        {
            "status": "ok" if ready else "degraded",
            "checks": {name: {"ok": ok, "detail": detail} for name, (ok, detail) in results.items()},
        },
        status_code=200 if ready else 503,
    )


# ---------- transfers ----------

def row_to_json(row):
    return {
        "id": str(row[0]),
        "amount": f"{row[1] / 100:.2f}",
        "currency": row[2],
        "recipient": row[3],
        "status": row[4],
        "provider_reference": row[5],
        "client_ip": row[6],
    }


SELECT = "SELECT id, amount_minor, currency, recipient, status, provider_reference, client_ip FROM transfers WHERE id = %s"


async def create_transfer(request):
    try:
        amount, currency, recipient = parse_transfer(await request.json())
    except (InvalidTransfer, ValueError) as exc:
        return count(request, JSONResponse({"error": str(exc)}, status_code=400))
    transfer_id = uuid.uuid4()
    client_ip = request.client.host if request.client else None
    with psycopg.connect(settings.dsn) as conn:
        conn.execute(
            "INSERT INTO transfers (id, amount_minor, currency, recipient, status, client_ip) VALUES (%s, %s, %s, %s, %s, %s)",
            (transfer_id, to_minor(amount), currency, recipient, "PENDING", client_ip),
        )
        row = conn.execute(SELECT, (transfer_id,)).fetchone()
    broker.publish(
        settings,
        {"transfer_id": str(transfer_id), "request_id": request_id_var.get()},
    )
    log.info("transfer created", extra={"transfer_id": str(transfer_id), "client_ip": client_ip})
    return count(request, JSONResponse(row_to_json(row), status_code=202))


async def get_transfer(request):
    try:
        transfer_id = uuid.UUID(request.path_params["transfer_id"])
    except ValueError:
        return count(request, JSONResponse({"error": "not found"}, status_code=404))
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(SELECT, (transfer_id,)).fetchone()
    if row is None:
        return count(request, JSONResponse({"error": "not found"}, status_code=404))
    return count(request, JSONResponse(row_to_json(row)))


async def metrics(request):
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


app = Starlette(
    routes=[
        Route("/health", health),
        Route("/health/ready", health_ready),
        Route("/health/db", health_db),
        Route("/health/rabbit", health_rabbit),
        Route("/metrics", metrics),
        Route("/transfers", create_transfer, methods=["POST"]),
        Route("/transfers/{transfer_id}", get_transfer),
    ],
    middleware=[Middleware(RequestIDMiddleware)],
)