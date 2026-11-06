#!/bin/sh
set -e
if [ ! -f /certs/cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout /certs/key.pem -out /certs/cert.pem -subj "/CN=mock-provider" -addext "subjectAltName=DNS:mock-provider" 2>/dev/null
fi
exec uvicorn app:app --host 0.0.0.0 --port 9443 --ssl-keyfile /certs/key.pem --ssl-certfile /certs/cert.pem --no-access-log
