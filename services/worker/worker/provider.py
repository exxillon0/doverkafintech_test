import requests
import urllib3

urllib3.disable_warnings()


def send_payout(settings, transfer_id, amount, currency, recipient):
    response = requests.post(
        f"{settings.provider_url}/payouts",
        json={"reference": str(transfer_id), "amount": str(amount), "currency": currency, "recipient": recipient},
        headers={"X-Api-Key": settings.provider_api_key, "Idempotency-Key": str(transfer_id)},
        timeout=10,
        verify=False,
    )
    response.raise_for_status()
    return response.json()
