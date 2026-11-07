#!/bin/sh
set -e
CERT_DIR="${MOCK_PROVIDER_CERTS_DIR:-/tmp/mock-certs}"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=mock-provider" -addext "subjectAltName=DNS:mock-provider" 2>/dev/null
fi
exec uvicorn app:app --host 0.0.0.0 --port 9443 --ssl-keyfile "$CERT_DIR/key.pem" --ssl-certfile "$CERT_DIR/cert.pem" --no-access-log
