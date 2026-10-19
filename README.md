# deploy — RTK School CRM

<sub>Команда **«Тесткит»** — [github.com/lct-testkit](https://github.com/lct-testkit)</sub>

Инфраструктурный репозиторий проекта RTK School CRM: сборка образов,
CI/CD, развёртывание (живой стенд, Kubernetes, офлайн-поставка).
Бизнес-логика живёт в соседних репозиториях организации `lct-testkit` —
`backend` (FastAPI), `frontend` (SvelteKit), `rt-ui` (дизайн-система). Пошаговая
инструкция — [`RUNBOOK.md`](RUNBOOK.md): конвейер поставки, провижининг VM,
первый деплой, автодеплой, откат, офлайн-установка, бэкап/восстановление, Helm.

## Как устроена поставка

Образ попадает на стенды только пройдя гейты: `backend`/`frontend` публикуют образ
(общий workflow [`docker-publish.yml`](.github/workflows/docker-publish.yml): сборка →
Trivy → push → SBOM/provenance → подпись cosign), а `notify.yml` перед записью в
`images.yaml` проверяет образ в GHCR и **поднимает стек с ним и гоняет smoke**.
Подробная схема — в [`RUNBOOK.md`](RUNBOOK.md#конвейер-поставки-cicd-целиком).

## Состав репозитория

| Путь | Назначение |
|---|---|
| `images.yaml` | Единый источник истины по образам: реестр, tag/digest, внешние образы (по digest), сервисы, профили |
| `compose/` | Прод-профиль docker-compose. Литералов образов нет — только `<ИМЯ>_IMAGE` из `.env.images` |
| `charts/rtk-crm/` | Helm-чарт (та же топология); проверяется lint + kubeconform + drift |
| `mocks/lms`, `mocks/cms` | Заглушки внешних контрактов (LMS, Laravel CMS), профиль compose `integrations` |
| `compose/prometheus/`, `compose/grafana/` | Профиль compose `monitoring` / `values.monitoring.enabled` в чарте: Prometheus (TSDB на volume) + Grafana (датасорс и 2 дашборда — file-based provisioning, не через UI), `/grafana` за Caddy |
| `compose/` сервис `mailpit` | Профиль compose `mail`: Mailpit — ловушка писем демо-стенда (приглашения, сброс пароля, ссылки подписантам, уведомления, письма Keycloak), интерфейс `/mail` за Caddy, только чтение (demo — всем, prod — после входа в CRM); для demo включён по умолчанию (`install.sh --no-mail` отключает) |
| `scripts/render_env_images.py` | `images.yaml` → `.env.images` (режимы `digest` / `bundle` / `registry`) |
| `scripts/gen_env.sh`, `lib_host.sh` | Секреты + согласованные `runtime/keycloak/realm-crm.json` и `runtime/seaweedfs/s3.json`; `--host`, `--tls off\|internal\|acme`, `--fonts`, `--port-offset`. `lib_host.sh` — общие функции адреса и режима TLS |
| `scripts/kc_apply_email_theme.sh` | Выбор русской email-темы `rtk-crm` в realm Keycloak у уже установленного стенда (на новой установке тему выбирает импорт realm); вызывается из `install.sh` и `deploy.sh` |
| `compose/ha/` | HA на трёх узлах: `rqlite.yml` — кластер rqlite для хранилища писем Mailpit (`MAILPIT_DATABASE`), отдельный compose-проект на каждом узле, не профиль основного compose |
| `scripts/set_host.sh` | Смена адреса и режима TLS у установленного стенда: `.env`, realm, адреса клиента в БД Keycloak, перезапуск |
| `scripts/deploy.sh` | Деплой окружения (`--init`, `rollback`): бэкап → `up --wait` → smoke → автооткат |
| `scripts/smoke.sh`, `e2e_stack.sh` | Дымовая проверка и сквозной сценарий стенда (up → smoke → бэкап → восстановление) |
| `scripts/backup.sh`, `restore_test.sh` | Резервная копия и проверка восстановления (спека §6) |
| `scripts/build_offline_bundle.sh`, `bundle_install.sh`, `registry_load.sh` | Офлайн-бандл: образы + compose + установщик + `SHA256SUMS`; внутренний registry. `install.sh` спрашивает окружение (demo/prod), адрес и нужны ли моковые данные |
| `seed/`, `scripts/seed_demo.sh`, `sync_seed.sh` | Моковые данные демо-стенда (профиль compose `demo-data`): три скрипта в контейнере node, копии из `frontend/tools`; `sync_seed.sh` их обновляет/сверяет |
| `scripts/check_drift.py`, `validate_images.py` | Сверка compose/chart/копий конфигов с `images.yaml`; валидация манифеста |
| `scripts/apply_and_push.sh`, `verify_image.sh`, `update_image_refs.py` | Запись в `images.yaml` ботом: проверка образа в GHCR, ретраи push |
| `scripts/provision_vm.sh`, `install_autodeploy.sh` | Подготовка VM и systemd-таймер автодеплоя (demo/dev) |
| `.github/workflows/docker-publish.yml` | Общий конвейер публикации образа (вызывается из backend/frontend) |
| `.github/workflows/notify.yml` | Приём dispatch: проверка образа → стек с новым образом → коммит в `images.yaml` |
| `.github/workflows/validate.yml` | yamllint, actionlint, shellcheck, hadolint, compose/helm, drift |
| `.github/workflows/e2e.yml` | Стенд из образов + бэкап/восстановление (на PR и ночью); офлайн-бандл без сети — только на релизе и только на GitHub-hosted раннере (пока их нет, релиз идёт вручную без этого шага, [`docs/ci-self-hosted.md`](docs/ci-self-hosted.md)) |
| `.github/workflows/build.yml` | Сборка образов deploy-репо: моки и сайт школы `site` (self-hosted, multi-arch, Trivy, cosign; [`docs/ci-self-hosted.md`](docs/ci-self-hosted.md)) |
| `site/`, `docs/site.md` | Сайт ИТ-Школы РТК на Laravel (профиль compose `site`): лендинг, форма заявки, API `GET /api/v1/leads` для CRM; интерфейс на rt-ui |
| `.github/workflows/release.yml` | На теге `vX.Y.Z`: e2e → бандл → подпись → GitHub Release |
| `docs/ghcr-setup.md`, `docs/REPO-SETTINGS.md` | Ручные шаги (токены, GHCR) и настройки репозиториев организации |
| `docs/ci-self-hosted.md` | Почему CI гоняется на self-hosted раннере `lct`, что где идёт, как выпустить релиз без GitHub-hosted |
| `docs/ha-patroni.md` | HA на трёх узлах (Patroni + etcd + SeaweedFS): схема, развёртывание, скрипты failover, результаты проверок |

Realm Keycloak (`realm-crm.json`), `s3.json`, `init-keycloak-db.sh`, `Caddyfile` — копии из
`backend/deploy/`; `check_drift.py --backend-dir` (job `drift`) падает, если копии разошлись.

Реестр образов — GHCR (`ghcr.io/lct-testkit`), приватные пакеты.

## Локальная проверка перед пушем

```bash
pip install -r scripts/requirements.txt
python scripts/validate_images.py images.yaml
python scripts/check_drift.py --backend-dir ../backend
python scripts/render_env_images.py > /tmp/env.images
docker compose -f compose/docker-compose.yml --env-file compose/.env.example --env-file /tmp/env.images \
  --profile integrations --profile registry --profile demo-data --profile monitoring --profile mail config --quiet
yamllint --strict -c .yamllint.yml .
bash scripts/e2e_stack.sh --with-restore     # нужен docker login ghcr.io; ~5–8 минут
```

Статические проверки гоняются в CI (`validate.yml`) на каждый PR; e2e — на PR, затрагивающие
`compose/`, `scripts/`, `images.yaml`, а также ночью.

## Лицензия

Apache-2.0 — файл [`LICENSE`](LICENSE). Материалы третьих лиц (шрифт Rostelecom Basis, товарные знаки и фирменные ассеты Ростелекома, сторонние зависимости) в лицензию не входят — [`NOTICE`](NOTICE).
