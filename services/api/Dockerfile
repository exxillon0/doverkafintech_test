# фикс. версии образов + multi-stage
#stage 1
FROM python:3.11-slim AS builder 

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY services/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# stage 2
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --uid 1000 appuser

WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

COPY services/api/app ./app
COPY migrations ./migrations
COPY services/api/entrypoint.sh ./entrypoint.sh
RUN chmod +x entrypoint.sh && chown -R appuser:appuser /app

USER appuser
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]