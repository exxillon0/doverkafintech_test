"""Тестовые env до импорта app.main — иначе load_settings() упадёт с SystemExit."""
import os

os.environ.setdefault("POSTGRES_HOST", "localhost")
os.environ.setdefault("POSTGRES_DB", "payments")
os.environ.setdefault("POSTGRES_USER", "payments")
os.environ.setdefault("POSTGRES_PASSWORD", "test-password")
os.environ.setdefault("RABBITMQ_HOST", "localhost")
os.environ.setdefault("RABBITMQ_USER", "payments")
os.environ.setdefault("RABBITMQ_PASSWORD", "test-password")
os.environ.setdefault("LOG_LEVEL", "INFO")