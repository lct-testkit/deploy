# deploy — RTK School CRM

Инфраструктурный репозиторий проекта RTK School CRM: сборка образов,
CI/CD, развёртывание (живой демо-стенд, Kubernetes, офлайн-поставка).
Бизнес-логика живёт в соседних репозиториях организации `lct-testkit` —
`backend` (FastAPI) и `frontend` (SvelteKit). Пошаговая инструкция —
[`RUNBOOK.md`](RUNBOOK.md): провижининг VM, первый деплой, автодеплой,
откат, Kubernetes/Helm, офлайн-установка, бэкап/восстановление.

## Состав репозитория

| Путь | Назначение | Статус |
|---|---|---|
| `images.yaml` | Единый источник истины по образам: реестр, теги/digest, сервисы, профили | готово, 6 внешних образов запинены по digest с живого стенда; `api`/`web` — без tag/digest до первой сборки CI |
| `scripts/validate_images.py` | Валидация `images.yaml` | готово |
| `scripts/check_drift.py` | Сверка `compose/` и `charts/` с `images.yaml` (расхождение digest/имени образа) | готово |
| `scripts/render_env_images.py`, `deploy.sh`, `install_autodeploy.sh` | Автодеплой на VM: тег из `images.yaml` → `.env.images` → `docker compose pull/up`, systemd-таймер | готово |
| `scripts/build_offline_bundle.sh` | Сборка офлайн-архива (образы + `compose/` + `install.sh`) | готово, сборка проверена вживую (6 внешних образов) |
| `scripts/provision_vm.sh` | Подготовка VM: Docker/compose, пользователь `deploy`, каталоги, swap | готово |
| `.github/workflows/validate.yml` | CI: yamllint, валидация манифеста, hadolint, compose/helm/drift | готово, все джобы теперь реально выполняются (не `exit 0`-заглушки) |
| `.github/workflows/build.yml` | Сборка и публикация образов моков в GHCR | готово |
| `.github/workflows/notify.yml` | Приём `repository_dispatch` от backend/frontend, обновление `images.yaml` | готово |
| `.github/workflows/release.yml` | На теге `vX.Y.Z` — сборка и публикация офлайн-бандла релизом GitHub | готово |
| `compose/` | Прод-профиль docker-compose (готовые образы `ghcr.io/lct-testkit/*`, не сборка) | готово: `docker compose config --quiet` проходит |
| `charts/rtk-crm/` | Helm-чарт — та же топология в Kubernetes | готово: `helm lint` и `helm template \| kubeconform -strict` проходят (26 объектов, 0 ошибок) |
| `mocks/lms`, `mocks/cms` | Заглушки внешних контрактов (LMS, Laravel CMS) | готово |

Realm Keycloak (`realm-crm.json`) и вспомогательные конфиги (`init-keycloak-db.sh`, `s3.json`) — копии из `backend/deploy/`, продублированы в `compose/` и `charts/rtk-crm/files/` независимо (не через общий источник в этом репозитории) — при правке realm в `backend` обновите обе копии.

Реестр образов — GHCR (`ghcr.io/lct-testkit`), приватные пакеты.

## Локальная проверка перед пушем

```bash
python scripts/validate_images.py images.yaml
python scripts/check_drift.py
yamllint --strict -c .yamllint.yml .
docker compose -f compose/docker-compose.yml --env-file compose/.env.example config --quiet
helm lint charts/rtk-crm
```

Все пять также гоняются в CI (`validate.yml`) на каждый PR и push в `main`.
