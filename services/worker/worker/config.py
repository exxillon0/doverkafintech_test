import os
from dataclasses import dataclass


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is not set")
    return value


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_name: str
    db_user: str
    db_password: str
    rabbitmq_host: str
    rabbitmq_user: str
    rabbitmq_password: str
    provider_url: str
    provider_api_key: str
    provider_ca_bundle: str
    log_level: str

    @property
    def dsn(self):
        return f"host={self.db_host} dbname={self.db_name} user={self.db_user} password={self.db_password} connect_timeout=3"


def load_settings():
    return Settings(
        db_host=os.environ.get("DB_HOST", "db"),
        db_name=os.environ.get("POSTGRES_DB", "payments"),
        db_user=os.environ.get("POSTGRES_USER", "payments"),
        db_password=required("POSTGRES_PASSWORD"),
        rabbitmq_host=os.environ.get("RABBITMQ_HOST", "rabbitmq"),
        rabbitmq_user=os.environ.get("RABBITMQ_DEFAULT_USER", "payments"),
        rabbitmq_password=required("RABBITMQ_DEFAULT_PASS"),
        provider_url=os.environ.get("PROVIDER_URL", "https://mock-provider:9443"),
        provider_api_key=required("PROVIDER_API_KEY"),
        provider_ca_bundle=os.environ.get("PROVIDER_CA_BUNDLE", "/certs/cert.pem"),
        log_level=os.environ.get("LOG_LEVEL", "INFO"),
    )
