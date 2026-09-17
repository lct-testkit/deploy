# deploy — RTK School CRM

Инфраструктурный репозиторий проекта RTK School CRM: сборка образов,
CI/CD, развёртывание (живой демо-стенд и офлайн-поставка). Бизнес-логика
живёт в соседних репозиториях организации `lct-testkit` — `backend`
(FastAPI) и `frontend` (SvelteKit). Полный план работ и принятые решения —
в `DEVOPS_PLAN.md` (не публикуется, см. `.gitignore`).

## Состав репозитория

| Путь | Назначение | Статус |
|---|---|---|
| `images.yaml` | Единый источник истины по образам: реестр, теги/digest, сервисы, профили | заполняется по фазам |
| `scripts/validate_images.py` | Валидация `images.yaml` | готово |
| `.github/workflows/validate.yml` | CI: yamllint, валидация манифеста, hadolint, compose/helm/drift (включаются по мере появления артефактов) | готово |
| `compose/` | docker-compose для профилей `core`/`integrations`/`storage` | заготовка |
| `keycloak/` | Realm как код (`keycloak-config`) | заготовка |
| `charts/rtk-crm/` | Umbrella Helm-чарт | заготовка |
| `mocks/lms`, `mocks/cms` | Заглушки внешних контрактов (LMS, Laravel CMS) | заготовка |

Реестр образов — GHCR (`ghcr.io/lct-testkit`), приватные пакеты.

## Локальная проверка перед пушем

```bash
python scripts/validate_images.py images.yaml
yamllint --strict -c .yamllint.yml .
```

Оба шага также гоняются в CI (`validate.yml`) на каждый PR и push в `main`.
