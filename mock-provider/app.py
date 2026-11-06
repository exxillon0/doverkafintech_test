import os
import uuid

from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

state = {"failing": False, "payouts": {}}
API_KEY = os.environ.get("PROVIDER_API_KEY", "")


async def health(request):
    return JSONResponse({"status": "ok", "failing": state["failing"]})


async def create_payout(request):
    if not API_KEY or request.headers.get("X-Api-Key") != API_KEY:
        return JSONResponse({"code": "UNAUTHORIZED"}, status_code=401)
    if state["failing"]:
        return JSONResponse({"code": "INTERNAL_ERROR"}, status_code=503)
    key = request.headers.get("Idempotency-Key") or uuid.uuid4().hex
    body = await request.json()
    payout = state["payouts"].setdefault(
        key, {"payout_id": f"po_{uuid.uuid4().hex[:16]}", "status": "COMPLETED", "reference": body.get("reference")}
    )
    return JSONResponse(payout, status_code=201)


async def set_failing(request):
    body = await request.json()
    state["failing"] = bool(body.get("enabled"))
    return JSONResponse({"failing": state["failing"]})


app = Starlette(
    routes=[
        Route("/health", health),
        Route("/payouts", create_payout, methods=["POST"]),
        Route("/admin/fail-mode", set_failing, methods=["POST"]),
    ]
)
