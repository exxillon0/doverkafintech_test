import json

import pika

QUEUE = "transfers"
DLX = "transfers.dlx"


def publish(settings, message):
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    parameters = pika.ConnectionParameters(
        host=settings.rabbitmq_host,
        credentials=credentials,
        socket_timeout=3,
    )
    connection = pika.BlockingConnection(parameters)
    try:
        channel = connection.channel()
        # Declare with SAME args as worker — otherwise RabbitMQ rejects with
        # PRECONDITION_FAILED (inequivalent x-dead-letter-exchange).
        channel.queue_declare(
            queue=QUEUE,
            durable=True,
            arguments={"x-dead-letter-exchange": DLX},
        )
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=2),
        )
    finally:
        connection.close()