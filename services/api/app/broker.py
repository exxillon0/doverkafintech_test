import json

import pika

QUEUE = "transfers"


def publish(settings, message):
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    parameters = pika.ConnectionParameters(host=settings.rabbitmq_host, credentials=credentials, socket_timeout=3)
    connection = pika.BlockingConnection(parameters)
    try:
        channel = connection.channel()
        channel.queue_declare(queue=QUEUE, durable=True)
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=2),
        )
    finally:
        connection.close()
