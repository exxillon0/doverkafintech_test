import logging
import uuid

import psycopg
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from starlette.applications import Starlette
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import broker
from .config import load_settings
from .validation import InvalidTransfer, parse_transfer, to_minor

settings = load_settings()
logging.basicConfig(level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("api")
log.info("starting with settings %s", settings)

REQUESTS = Counter("api_requests_total", "HTTP requests", ["method", "path", "status"])


def count(request, response):
    REQUESTS.labels(request.method, request.url.path.split("/")[1], response.status_code).inc()
    return response


async def health(request):
    return JSONResponse({"status": "ok"})


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
    broker.publish(settings, {"transfer_id": str(transfer_id)})
    log.info("transfer created id=%s client_ip=%s", transfer_id, client_ip)
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
        Route("/metrics", metrics),
        Route("/transfers", create_transfer, methods=["POST"]),
        Route("/transfers/{transfer_id}", get_transfer),
    ]
)
