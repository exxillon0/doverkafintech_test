#!/bin/sh
set -e
python -m app.migrate
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-access-log
