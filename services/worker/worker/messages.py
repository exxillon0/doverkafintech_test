import json
import uuid


class PoisonMessage(Exception):
    pass


def parse_message(body):
    try:
        payload = json.loads(body)
        return uuid.UUID(payload["transfer_id"])
    except (ValueError, KeyError, TypeError) as exc:
        raise PoisonMessage(str(exc)) from exc
