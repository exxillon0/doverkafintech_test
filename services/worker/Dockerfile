FROM python:latest
RUN apt-get update && apt-get upgrade -y
WORKDIR /app
COPY services/worker/requirements.txt .
RUN pip install -r requirements.txt
COPY services/worker/worker ./worker
EXPOSE 8001
CMD ["python", "-m", "worker.consumer"]
