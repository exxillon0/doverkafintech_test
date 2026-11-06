# Payment Stack
cd deploy && ./deploy.sh stage
curl -X POST http://localhost:8080/transfers -H 'Content-Type: application/json' -d '{"amount":"100.00","currency":"RUB","recipient":"TH1234567890"}'
