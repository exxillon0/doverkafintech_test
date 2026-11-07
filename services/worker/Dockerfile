# фикс версии + multi-stage building
#stage 1
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY services/worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
#stage 2
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --uid 1000 appuser

WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

COPY services/worker/worker ./worker
RUN chown -R appuser:appuser /app

USER appuser
EXPOSE 8001
HEALTHCHECK --interval=10s --timeout=3s --retries=5 --start-period=20s \
  CMD python -c "import sys,urllib.request; urllib.request.urlopen('http://localhost:8001/metrics', timeout=2); sys.exit(0)"
CMD ["python", "-m", "worker.consumer"]