# RTK School CRM — прод-профиль docker compose

Тот же стек и та же топология сервисов, что в `backend/docker-compose.yml`
(PostgreSQL 16, Redis 7, SeaweedFS, Keycloak 25, Caddy, arq — раздел
спецификации по составу контура), с одним отличием:

| | `backend/docker-compose.yml` | этот файл (`deploy/compose/`) |
|---|---|---|
| Образы `api`/`worker`/`migrate`/`seed`/`sms-gateway-mock` | `build: .` (собираются из исходников `backend/`) | `image: ghcr.io/lct-testkit/api:${API_TAG:-latest}` (готовый образ) |
| Образ `web` | `build: ../frontend` | `image: ghcr.io/lct-testkit/web:${WEB_TAG:-latest}` (готовый образ) |
| Внешние образы (`postgres`, `redis`, `keycloak`, `seaweedfs`, `caddy`, `ntp`) | тег без пина | тот же тег, запинненный по digest из `../images.yaml` |
| Назначение | локальная разработка/демо на машине разработчика | реальный сервер — не требует исходников `backend`/`frontend`, только Docker и доступ к `ghcr.io/lct-testkit/*` |

Остальное — healthcheck'и, `depends_on`, volumes, сети, переменные окружения
(whitelist `x-api-env`) — скопировано без изменений из `backend/docker-compose.yml`.

## Файлы

- `docker-compose.yml` — сам стек.
- `.env.example` — переменные окружения (та же структура и дефолты, что
  `backend/.env.example`, плюс `API_TAG`/`WEB_TAG` внизу).
- `Caddyfile` — точная копия `backend/deploy/Caddyfile` (тот же `dynamic a`
  upstream на `api`, он корректно резолвится через встроенный DNS Docker
  Compose — в отличие от Helm-версии, см. `../charts/rtk-crm/`).
- `postgres/init-keycloak-db.sh`, `seaweedfs/s3.json`, `keycloak/realm-crm.json`
  — verbatim-копии соответствующих файлов из `backend/deploy/` (bind-mount'ятся
  в контейнеры, путь ссылок в `docker-compose.yml` — уже относительно этого каталога).

## Запуск

```bash
cp .env.example .env
# отредактировать .env — ОБЯЗАТЕЛЬНО сменить секреты, помеченные
# "СМЕНИТЬ ДЛЯ PROD" (POSTGRES_PASSWORD, CRM_APP_PASSWORD,
# KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_CLIENT_SECRET,
# KEYCLOAK_ADMIN_CLIENT_SECRET, SIGNATURE_SERVER_SECRET, S3_ACCESS_KEY,
# S3_SECRET_KEY) — дефолты подходят только для демо/оценки.

docker compose up -d              # ядро контура (postgres, redis, seaweedfs, ntp,
                                   # sms-gateway-mock, keycloak, migrate, seed, api, worker, caddy)
docker compose --profile web up -d   # то же плюс web — так же, как в backend/docker-compose.yml
```

Приложение будет доступно на `http://<сервер>:${HTTP_PORT:-8080}` (и
`https://<сервер>:${HTTPS_PORT:-8443}` с самоподписанным сертификатом
`tls internal`).

## Проверка конфигурации

```bash
docker compose --env-file .env.example config --quiet
```

Ничего не должно быть выведено и код возврата должен быть `0` — значит YAML
и все `${...}`-подстановки валидны.
