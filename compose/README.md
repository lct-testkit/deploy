# RTK School CRM — прод-профиль docker compose

Тот же стек и та же топология сервисов, что в `backend/docker-compose.yml`
(PostgreSQL 16, Redis 7, SeaweedFS, Keycloak 25, Caddy, arq — раздел
спецификации по составу контура), с отличиями:

| | `backend/docker-compose.yml` | этот файл (`deploy/compose/`) |
|---|---|---|
| Образы `api`/`worker`/`migrate`/`seed`/`sms-gateway-mock`, `web` | `build:` (из исходников) | `image: ${API_IMAGE}` / `${WEB_IMAGE}` — готовые образы по digest |
| Внешние образы (`postgres`, `redis`, `keycloak`, `seaweedfs`, `caddy`, `ntp`) | тег без пина | `${POSTGRES_IMAGE}` и т.д. — запинены по digest в `../images.yaml` |
| Назначение | локальная разработка/демо на машине разработчика | реальный сервер: только Docker и образы (GHCR, внутренний registry или офлайн-бандл) |

**В файле нет литералов образов.** Все ссылки — переменные `<ИМЯ>_IMAGE`, которые
генерирует `../scripts/render_env_images.py` из `../images.yaml`. Без `.env.images`
compose не стартует (fail closed) — так «в compose один digest, а в манифесте другой»
невозможно.

## Файлы

- `docker-compose.yml` — сам стек. Профили: без флага — весь боевой стек (включая `web`);
  `integrations` — `mock-lms`/`mock-cms`; `registry` — внутренний registry (`127.0.0.1:5000`);
  `demo-data` — одноразовый `seed-demo` (node) с моковыми данными, его запускает `../scripts/seed_demo.sh`
  после `up --wait` (только `APP_PROFILE=demo`; скрипты лежат в `../seed`); `monitoring` — Prometheus +
  Grafana (дашборды по метрикам `api`/`worker`/`keycloak` из `prometheus/`, `grafana/`), отдаётся через Caddy на
  `/grafana` — см. `../RUNBOOK.md`, «Мониторинг и логи».
- `.env.example` — переменные окружения (структура и дефолты как в `backend/.env.example`).
  Секретов там демо-значения; боевой `.env` генерирует `../scripts/gen_env.sh`.
- `Caddyfile`, `postgres/init-keycloak-db.sh`, `seaweedfs/s3.json`, `keycloak/realm-crm.json`
  — копии файлов из `backend/deploy/` (сверяет `../scripts/check_drift.py --backend-dir`).
  `s3.json` и `realm-crm.json` — ДЕМО-версии с публичными секретами; для боя
  `gen_env.sh` создаёт их сгенерированные варианты в `runtime/` и прописывает пути в `.env`
  (`SEAWEED_S3_CONFIG`, `KEYCLOAK_IMPORT_DIR`).

## Запуск

```bash
bash ../scripts/gen_env.sh --dir . --profile demo          # .env + runtime/ со случайными секретами
python3 ../scripts/render_env_images.py > .env.images       # ссылки на образы из images.yaml
docker compose --env-file .env --env-file .env.images up -d --wait
bash ../scripts/smoke.sh http://localhost:8080
```

По умолчанию (`gen_env.sh` без `--tls`, режим `off`) приложение — `http://<сервер>:${HTTP_PORT:-8080}` (и
`https://<сервер>:${HTTPS_PORT:-8443}` с самоподписанным сертификатом `tls internal`). Наружу публикуются только порты
Caddy; PostgreSQL — только на loopback хоста (`127.0.0.1:${POSTGRES_PORT:-5433}`).
Для нескольких окружений на одной машине: `-p <имя-проекта>` и `gen_env.sh --port-offset N`.

## Режимы TLS и порты

Режим задаёт `gen_env.sh --tls` (переменная `TLS_MODE`, остальное производное; менять руками не нужно, для смены на
работающем стенде есть `../scripts/set_host.sh`). Подробности и предполётные проверки: `../RUNBOOK.md`, «Домен и TLS».

| Порт хоста | `off` | `internal` / `acme` |
|---|---|---|
| `HTTP_PORT` → 8080 (plain http) | `0.0.0.0:8080+N` | только `127.0.0.1:8080` (Docker обходит ufw, наружу не нужен) |
| `HTTPS_PORT` → TLS-сайт Caddy (`CRM_TLS_PORT`) | `8443+N` → 8443, самоподписанный | `443` → 443, tcp и udp (HTTP/3); `internal` самоподписанный, `acme` Let's Encrypt |
| `CRM_PORT80_PUBLISH` → 80 | `127.0.0.1::80` (наружу не публикуется) | `80:80`: выпуск сертификата (HTTP-01) и редирект на https |
| `S3_PROXY_PORT` → 8333 (presigned-ссылки) | `8333+N`, plain http | `8333`, https (тот же сертификат) |

Переменные Caddy (`CRM_TLS_HOST`, `CRM_TLS_PORT`, `CRM_TLS_SNIPPET`, `S3_SITE_ADDRESS`, `S3_TLS_SNIPPET`) описаны в шапке
`Caddyfile` и в блоке «Режим TLS» файла `.env.example`. Шрифты Rostelecom Basis монтируются из `${FONTS_DIR:-./fonts}`
(каталог с `*.woff`, не входят в git и образ `web`).
Для боя и автодеплоя используйте `../scripts/deploy.sh` (см. `../RUNBOOK.md`).

## Проверка конфигурации

```bash
python3 ../scripts/render_env_images.py > /tmp/env.images
docker compose --env-file .env.example --env-file /tmp/env.images \
  --profile integrations --profile registry --profile demo-data --profile monitoring config --quiet
```

Ничего не выводится, код возврата `0` — YAML и все `${...}`-подстановки валидны.
