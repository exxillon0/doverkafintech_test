FROM python:latest
RUN apt-get update && apt-get upgrade -y
WORKDIR /app
COPY mock-provider/requirements.txt .
RUN pip install -r requirements.txt
COPY mock-provider/app.py mock-provider/entrypoint.sh ./
EXPOSE 9443
ENTRYPOINT ["./entrypoint.sh"]
