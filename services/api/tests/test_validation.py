from decimal import Decimal

import pytest

from app.validation import InvalidTransfer, parse_transfer, to_minor


def test_valid_transfer():
    assert parse_transfer({"amount": "100.50", "currency": "RUB", "recipient": " TH1 "}) == (Decimal("100.50"), "RUB", "TH1")


@pytest.mark.parametrize(
    "body",
    [
        {"amount": "1", "currency": "RUB", "recipient": "x"},
        {"amount": "0.00", "currency": "RUB", "recipient": "x"},
        {"amount": "1.00", "currency": "rub", "recipient": "x"},
        {"amount": "1.00", "currency": "RUB", "recipient": " "},
        {"amount": 1, "currency": "RUB", "recipient": "x"},
        [],
    ],
)
def test_invalid_transfer(body):
    with pytest.raises(InvalidTransfer):
        parse_transfer(body)


def test_to_minor():
    assert to_minor(Decimal("100.50")) == 10050
