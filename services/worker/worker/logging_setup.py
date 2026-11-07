"""JSON-логи для worker. request_id приходит из сообщения."""
import contextvars
import json
import logging
import sys

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_id", default="-"
)


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
        for field in ("transfer_id", "status", "payout_id", "retry"):
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