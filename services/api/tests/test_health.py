from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.routing import Route
from starlette.testclient import TestClient

from app import main as app_main
from app.logging_setup import RequestIDMiddleware


def _client():
    # Используем настоящий app, но изолируем middleware, чтобы не тянуть settings
    app = Starlette(
        routes=[
            Route("/health", app_main.health),
            Route("/health/ready", app_main.health_ready),
        ],
        middleware=[Middleware(RequestIDMiddleware)],
    )
    return TestClient(app)


def test_health_liveness_always_ok():
    client = _client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_health_ready_ok_when_deps_up(monkeypatch):
    # Подменяем sync-проверки, чтобы не требовать реальных БД/RabbitMQ
    monkeypatch.setattr(app_main, "_check_db_sync", lambda: None)
    monkeypatch.setattr(app_main, "_check_rabbit_sync", lambda: None)
    client = _client()
    resp = client.get("/health/ready")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["checks"]["db"]["ok"] is True
    assert body["checks"]["rabbit"]["ok"] is True


def test_health_ready_503_when_db_down(monkeypatch):
    def boom():
        raise RuntimeError("db down")

    monkeypatch.setattr(app_main, "_check_db_sync", boom)
    monkeypatch.setattr(app_main, "_check_rabbit_sync", lambda: None)
    client = _client()
    resp = client.get("/health/ready")
    assert resp.status_code == 503
    body = resp.json()
    assert body["status"] == "degraded"
    assert body["checks"]["db"]["ok"] is False
    assert "db down" in body["checks"]["db"]["detail"]


def test_health_ready_503_when_rabbit_down(monkeypatch):
    def boom():
        raise RuntimeError("rabbit down")

    monkeypatch.setattr(app_main, "_check_db_sync", lambda: None)
    monkeypatch.setattr(app_main, "_check_rabbit_sync", boom)
    client = _client()
    resp = client.get("/health/ready")
    assert resp.status_code == 503
    assert resp.json()["checks"]["rabbit"]["ok"] is False