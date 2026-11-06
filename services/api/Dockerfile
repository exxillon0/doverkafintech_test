FROM python:latest
RUN apt-get update && apt-get upgrade -y
WORKDIR /app
COPY services/api/requirements.txt .
RUN pip install -r requirements.txt
COPY services/api/app ./app
COPY migrations ./migrations
COPY services/api/entrypoint.sh ./entrypoint.sh
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]
