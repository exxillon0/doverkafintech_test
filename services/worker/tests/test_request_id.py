import json
import logging

from worker.consumer import _extract_request_id
from worker.logging_setup import JsonFormatter, request_id_var


def test_extract_request_id_from_body():
    body = b'{"transfer_id": "abc", "request_id": "xyz"}'
    assert _extract_request_id(body) == "xyz"


def test_extract_request_id_missing():
    assert _extract_request_id(b'{"transfer_id": "abc"}') == "-"


def test_extract_request_id_invalid_json():
    assert _extract_request_id(b"not-json") == "-"


def test_json_formatter_includes_request_id():
    token = request_id_var.set("test-rid")
    try:
        record = logging.LogRecord(
            name="worker",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="test message",
            args=(),
            exc_info=None,
        )
        data = json.loads(JsonFormatter().format(record))
        assert data["request_id"] == "test-rid"
        assert data["msg"] == "test message"
    finally:
        request_id_var.reset(token)