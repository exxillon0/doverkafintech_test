## CI/CD Pipeline

Успешный прогон: https://github.com/exxillon0/doverkafintech_test/actions/runs/42389989594

### Быстрый старт (локально, без настройки секретов)

    make deploy ENV=stage APP_VERSION=dev
    make smoke ENV=stage

    # prod (dev-mode Vault, для демо)
    ALLOW_DEV_VAULT=1 make deploy ENV=prod APP_VERSION=dev