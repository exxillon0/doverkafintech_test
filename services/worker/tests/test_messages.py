import uuid

import pytest

from worker.messages import PoisonMessage, parse_message


def test_valid_message():
    value = uuid.uuid4()
    assert parse_message(f'{{"transfer_id": "{value}"}}'.encode()) == value


@pytest.mark.parametrize("body", [b"not json", b"{}", b'{"transfer_id": "nope"}', b"[]"])
def test_invalid_message(body):
    with pytest.raises(PoisonMessage):
        parse_message(body)
