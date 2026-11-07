import json
import logging

import pika
import psycopg
from prometheus_client import Counter, start_http_server

from .config import load_settings
from .logging_setup import request_id_var, setup_logging
from .messages import PoisonMessage, parse_message
from .provider import send_payout

log = logging.getLogger("worker")
QUEUE = "transfers"
MESSAGES = Counter("worker_messages_total", "Processed messages", ["result"])


def _extract_request_id(body: bytes) -> str:
    """request_id кладётся в payload api; если нет — '-'. Не падаем на битом JSON."""
    try:
        return json.loads(body).get("request_id", "-")
    except Exception:
        return "-"


def process(settings, body):
    transfer_id = parse_message(body)
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(
            "SELECT amount_minor, currency, recipient, status "
            "FROM transfers WHERE id = %s FOR UPDATE",
            (transfer_id,),
        ).fetchone()
        if row is None:
            raise LookupError(f"transfer {transfer_id} does not exist")
        amount_minor, currency, recipient, status = row
        if status != "PENDING":
            log.info(
                "skipping, status=%s",
                status,
                extra={"transfer_id": str(transfer_id)},
            )
            return
        payout = send_payout(
            settings, transfer_id, f"{amount_minor / 100:.2f}", currency, recipient
        )
        conn.execute(
            "UPDATE transfers SET status = %s, provider_reference = %s, "
            "updated_at = now() WHERE id = %s",
            (payout["status"], payout["payout_id"], transfer_id),
        )
    log.info(
        "transfer processed",
        extra={
            "transfer_id": str(transfer_id),
            "status": payout["status"],
            "payout_id": payout["payout_id"],
        },
    )


def main():
    settings = load_settings()
    setup_logging(settings.log_level)
    start_http_server(8001)

    credentials = pika.PlainCredentials(
        settings.rabbitmq_user, settings.rabbitmq_password
    )
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(
            host=settings.rabbitmq_host, credentials=credentials
        )
    )
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True)
    channel.basic_qos(prefetch_count=1)

    def on_message(ch, method, properties, body):
        token = request_id_var.set(_extract_request_id(body))
        try:
            process(settings, body)
        except PoisonMessage as exc:
            # битый payload / невалидный JSON — НЕ повторяем, иначе вечный цикл
            log.exception("poison message dropped", extra={"error": str(exc)})
            MESSAGES.labels("poison").inc()
            ch.basic_nack(method.delivery_tag, requeue=False)
        except Exception:
            # TODO(Level 3 step 3): DLX + retry counter + max_retries
            log.exception("failed to process message")
            MESSAGES.labels("failed").inc()
            ch.basic_nack(method.delivery_tag, requeue=True)
        else:
            MESSAGES.labels("processed").inc()
            ch.basic_ack(method.delivery_tag)
        finally:
            request_id_var.reset(token)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming", extra={"queue": QUEUE})
    channel.start_consuming()


if __name__ == "__main__":
    main()