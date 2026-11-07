import json
import logging

import pika
import psycopg
from prometheus_client import Counter, Gauge, start_http_server

from .config import load_settings
from .logging_setup import request_id_var, setup_logging
from .messages import PoisonMessage, parse_message
from .provider import send_payout

log = logging.getLogger("worker")

QUEUE = "transfers"
DLX = "transfers.dlx"
DLQ = "transfers.dlq"
RETRY_QUEUE = "transfers.retry"
MAX_RETRIES = 3
RETRY_TTL_MS = 5000

MESSAGES = Counter("worker_messages_total", "Processed messages", ["result"])
POISON = Counter("worker_poison_messages_total", "Messages sent to DLQ")
RETRIES = Counter("worker_retries_total", "Messages requeued for retry")
DLQ_SIZE = Gauge("worker_dlq_size", "Approximate DLQ size")


def _extract_request_id(body: bytes) -> str:
    try:
        return json.loads(body).get("request_id", "-")
    except Exception:
        return "-"


def _get_retry_count(properties: pika.BasicProperties) -> int:
    if not properties.headers:
        return 0
    try:
        return int(properties.headers.get("x-retry-count", 0))
    except (TypeError, ValueError):
        return 0


def _publish_with_retry_count(channel, routing_key, body, retry_count):
    channel.basic_publish(
        exchange="",
        routing_key=routing_key,
        body=body,
        properties=pika.BasicProperties(
            delivery_mode=2,
            headers={"x-retry-count": retry_count},
        ),
    )


def _update_dlq_size(channel):
    try:
        result = channel.queue_declare(queue=DLQ, durable=True, passive=True)
        DLQ_SIZE.set(result.method.message_count)
    except Exception:
        pass


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
            log.info("skipping, status=%s", status, extra={"transfer_id": str(transfer_id)})
            return
        payout = send_payout(settings, transfer_id, f"{amount_minor / 100:.2f}", currency, recipient)
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


def _declare_topology(channel):
    channel.exchange_declare(exchange=DLX, exchange_type="fanout", durable=True)
    channel.queue_declare(queue=DLQ, durable=True)
    channel.queue_bind(queue=DLQ, exchange=DLX)
    channel.queue_declare(
        queue=RETRY_QUEUE,
        durable=True,
        arguments={
            "x-message-ttl": RETRY_TTL_MS,
            "x-dead-letter-exchange": "",
            "x-dead-letter-routing-key": QUEUE,
        },
    )
    channel.queue_declare(
        queue=QUEUE,
        durable=True,
        arguments={"x-dead-letter-exchange": DLX},
    )


def main():
    settings = load_settings()
    setup_logging(settings.log_level)
    start_http_server(8001)

    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host=settings.rabbitmq_host, credentials=credentials)
    )
    channel = connection.channel()
    _declare_topology(channel)
    channel.basic_qos(prefetch_count=1)

    def on_message(ch, method, properties, body):
        token = request_id_var.set(_extract_request_id(body))
        retry_count = _get_retry_count(properties)
        try:
            process(settings, body)
        except PoisonMessage as exc:
            log.exception("poison message -> DLQ", extra={"error": str(exc)})
            POISON.inc()
            _publish_with_retry_count(ch, DLQ, body, retry_count)
            ch.basic_ack(method.delivery_tag)
        except Exception:
            if retry_count < MAX_RETRIES:
                log.warning("processing failed, retry %d/%d", retry_count + 1, MAX_RETRIES)
                RETRIES.inc()
                _publish_with_retry_count(ch, RETRY_QUEUE, body, retry_count + 1)
                ch.basic_ack(method.delivery_tag)
            else:
                log.exception("max retries reached (%d) -> DLQ", MAX_RETRIES)
                POISON.inc()
                _publish_with_retry_count(ch, DLQ, body, retry_count)
                ch.basic_ack(method.delivery_tag)
        else:
            MESSAGES.labels("processed").inc()
            ch.basic_ack(method.delivery_tag)
        finally:
            request_id_var.reset(token)
            _update_dlq_size(ch)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming", extra={"queue": QUEUE})
    channel.start_consuming()


if __name__ == "__main__":
    main()