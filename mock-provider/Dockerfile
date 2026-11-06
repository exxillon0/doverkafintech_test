# фикс версии + multi-stage building
#stage 1
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev openssl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY mock-provider/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
#stage 2
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --uid 1000 appuser

WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

COPY mock-provider/app.py mock-provider/entrypoint.sh ./
RUN chmod +x entrypoint.sh && chown -R appuser:appuser /app

USER appuser
EXPOSE 9443
HEALTHCHECK --interval=3s --timeout=3s --start-period=10s --retries=5 \
    CMD curl -fsSk https://localhost:9443/health || exit 1
ENTRYPOINT ["./entrypoint.sh"]