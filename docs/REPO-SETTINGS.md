# Настройки репозиториев организации

Часть защиты конвейера живёт не в файлах, а в настройках GitHub: без неё все гейты CI
можно обойти прямым пушем в `main`. Эти настройки нельзя закоммитить, поэтому они
описаны здесь и применяются скриптом [`scripts/apply_repo_settings.sh`](../scripts/apply_repo_settings.sh)
(dry-run по умолчанию, `--apply` — применить; нужен `gh` с правами админа организации).

> **Тарифы GitHub.** Rulesets и обязательные проверки в приватных репозиториях доступны на планах Team/Enterprise; code scanning (CodeQL) и secret scanning — только с GitHub Advanced Security. CodeQL-workflow из этого набора убран именно поэтому: без лицензии результаты некуда загрузить.

## Что и зачем

| Настройка | Где | Зачем |
|---|---|---|
| Ruleset `protect-main` | все 4 репозитория | Запрет удаления и force-push, линейная история, слияние только через PR с одним одобрением (ревью владельцев кода включите после создания команды из `CODEOWNERS` — `require_code_owner_review` в скрипте), все обязательные проверки зелёные и ветка актуальна |
| Обязательные проверки | ruleset | Имена = `name:` job'ов в workflows. Если переименуете job — обновите список в скрипте |
| Обход | все; бот — только `deploy` | Администраторы репозитория могут смержить PR без одобрения (иначе в команде из одного человека PR не смержить); в `deploy` GitHub Actions (integration 15368) пишет `images.yaml` прямо в `main` (`notify.yml`). Число одобрений — `REQUIRED_APPROVALS=0 bash scripts/apply_repo_settings.sh --apply` |
| Secret scanning + push protection | все (только с GitHub Advanced Security) | Токен не попадает в историю даже случайно. В приватных репозиториях функция платная: без неё скрипт пропускает шаг с предупреждением, а секреты в коде ловит Trivy в CI |
| Dependabot alerts / security updates | все | Уязвимые зависимости видны сразу; конфиг обновлений — `.github/dependabot.yml` |
| Права Actions по умолчанию = read | все | Workflow без явного `permissions:` не может писать; Actions не одобряет PR |
| Доступ к reusable workflow | `deploy` | Иначе `backend`/`frontend` не смогут вызвать `docker-publish.yml` («Accessible from repositories in the organization») |
| Слияние только squash | все | Один коммит на PR, линейная история |

## Секреты

| Секрет | Где | Что это |
|---|---|---|
| `DEPLOY_DISPATCH_TOKEN` | `backend`, `frontend` | Fine-grained PAT, только репозиторий `deploy`, `Contents: Read and write` (нужен для `repository_dispatch`) |
| `GHCR_PULL_TOKEN` | `deploy` | **Classic** PAT, scope `read:packages` (GHCR не поддерживает fine-grained) — чтение приватных образов `api`/`web` в `notify.yml`, `e2e.yml`, `release.yml` |
| `BACKEND_READ_TOKEN` | `deploy`, `frontend` (опционально) | Fine-grained PAT, только чтение `backend` (`Contents: Read`): `deploy` сверяет копии конфигов (job `drift`), `frontend` — свой контракт API с `backend@main`; без него эти сверки пропускаются с предупреждением |
| `NODE_AUTH_TOKEN` | `frontend` | Токен чтения GitHub Packages (`@lct-testkit/rt-ui`), см. раздел «rt-ui» ниже |

Подробности по токенам и GHCR — [`ghcr-setup.md`](ghcr-setup.md).

## rt-ui → frontend: пакет в GitHub Packages (выполнено)

Раньше `frontend` тянул дизайн-систему как `file:./vendor/lct-testkit-rt-ui-0.1.0.tgz` из вручную загруженного release `vendor-assets`;
версии расходились молча. Теперь `rt-ui` публикуется приватным пакетом `@lct-testkit/rt-ui` в GitHub Packages (`rt-ui/.github/workflows/release.yml`
по тегу `vX.Y.Z`), а `frontend` зависит от конкретной версии (`package.json`, `.npmrc` привязывает scope к реестру).

Как устроена авторизация (важно): **pnpm 11 игнорирует токены в `.npmrc` внутри репозитория** (защита от утечки токена на чужой реестр),
поэтому токен всегда подаётся через ПОЛЬЗОВАТЕЛЬСКИЙ конфиг:

| Где | Как |
|---|---|
| Локально | один раз: `pnpm config set "//npm.pkg.github.com/:_authToken" <classic PAT, scope read:packages>` |
| CI | `actions/setup-node` с `registry-url` и `scope` + `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` на уровне job'а |
| Docker | BuildKit-секрет `npm_token` → временный пользовательский `.npmrc`, удаляемый в том же `RUN` (`frontend/Dockerfile`) |

Доступ `GITHUB_TOKEN` репозитория `frontend` к пакету выдаётся в настройках пакета (Package settings → «Manage Actions access» → `frontend`, Read).
Публикация образа передаёт токен в reusable-workflow явно: `secrets: { NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }`.

Обновление версии дизайн-системы: новый тег `vX.Y.Z` в `rt-ui` → Dependabot (`npm`) присылает PR во `frontend`, либо вручную `pnpm add @lct-testkit/rt-ui@X.Y.Z`.

## Ручные шаги, которые остаются за владельцем

1. Применить настройки: `bash scripts/apply_repo_settings.sh --apply`.
2. Создать секреты из таблицы выше.
3. Удалить устаревшую ветку бота: `git push origin --delete bot/update-images-35271171079` (в `deploy`).
4. Выбрать лицензию (`frontend/README.md` прямо говорит, что её нет).
