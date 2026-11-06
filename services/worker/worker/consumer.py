import logging

import pika
import psycopg
from prometheus_client import Counter, start_http_server

from .config import load_settings
from .messages import parse_message
from .provider import send_payout

log = logging.getLogger("worker")
QUEUE = "transfers"
MESSAGES = Counter("worker_messages_total", "Processed messages", ["result"])


def process(settings, body):
    transfer_id = parse_message(body)
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(
            "SELECT amount_minor, currency, recipient, status FROM transfers WHERE id = %s FOR UPDATE", (transfer_id,)
        ).fetchone()
        if row is None:
            raise LookupError(f"transfer {transfer_id} does not exist")
        amount_minor, currency, recipient, status = row
        if status != "PENDING":
            return
        payout = send_payout(settings, transfer_id, f"{amount_minor / 100:.2f}", currency, recipient)
        conn.execute(
            "UPDATE transfers SET status = %s, provider_reference = %s, updated_at = now() WHERE id = %s",
            (payout["status"], payout["payout_id"], transfer_id),
        )
    log.info("transfer %s is %s", transfer_id, payout["status"])


def main():
    settings = load_settings()
    logging.basicConfig(level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    start_http_server(8001)
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    connection = pika.BlockingConnection(pika.ConnectionParameters(host=settings.rabbitmq_host, credentials=credentials))
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True)
    channel.basic_qos(prefetch_count=1)

    def on_message(ch, method, properties, body):
        try:
            process(settings, body)
        except Exception:
            log.exception("failed to process message")
            MESSAGES.labels("failed").inc()
            ch.basic_nack(method.delivery_tag, requeue=True)
        else:
            MESSAGES.labels("processed").inc()
            ch.basic_ack(method.delivery_tag)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming %s", QUEUE)
    channel.start_consuming()


if __name__ == "__main__":
    main()
