"""JSON-логи + request_id через contextvars. Без внешних зависимостей."""
import contextvars
import json
import logging
import sys
import time
import uuid

from starlette.middleware.base import BaseHTTPMiddleware

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_id", default="-"
)

SKIP_LOG_PATHS = frozenset({"/metrics"})


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        data = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        if record.exc_info:
            data["exc"] = self.formatException(record.exc_info)
        for field in ("method", "path", "status", "duration_ms", "transfer_id"):
            if hasattr(record, field):
                data[field] = getattr(record, field)
        return json.dumps(data, ensure_ascii=False)


def setup_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level.upper())
    # pika/prometheus_client слишком шумные на DEBUG — принудительно INFO
    for noisy in ("pika", "urllib3", "prometheus_client"):
        logging.getLogger(noisy).setLevel(logging.INFO)

class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        rid = request.headers.get("x-request-id") or str(uuid.uuid4())
        token = request_id_var.set(rid)
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers["X-Request-ID"] = rid
            return response
        finally:
            duration_ms = (time.perf_counter() - start) * 1000
            if request.url.path not in SKIP_LOG_PATHS:
                logging.getLogger("api.access").info(
                    "http_request",
                    extra={
                        "method": request.method,
                        "path": request.url.path,
                        "status": status,
                        "duration_ms": round(duration_ms, 2),
                    },
                )
            request_id_var.reset(token)