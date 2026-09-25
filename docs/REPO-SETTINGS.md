# Настройки репозиториев организации

Часть защиты конвейера живёт не в файлах, а в настройках GitHub: без неё все гейты CI
можно обойти прямым пушем в `main`. Эти настройки нельзя закоммитить, поэтому они
описаны здесь и применяются скриптом [`scripts/apply_repo_settings.sh`](../scripts/apply_repo_settings.sh)
(dry-run по умолчанию, `--apply` — применить; нужен `gh` с правами админа организации).

## Что и зачем

| Настройка | Где | Зачем |
|---|---|---|
| Ruleset `protect-main` | все 4 репозитория | Запрет удаления и force-push, линейная история, слияние только через PR с одним одобрением (ревью владельцев кода включите после создания команды из `CODEOWNERS` — `require_code_owner_review` в скрипте), все обязательные проверки зелёные и ветка актуальна |
| Обязательные проверки | ruleset | Имена = `name:` job'ов в workflows. Если переименуете job — обновите список в скрипте |
| Обход | все; бот — только `deploy` | Администраторы репозитория могут смержить PR без одобрения (иначе в команде из одного человека PR не смержить); в `deploy` GitHub Actions (integration 15368) пишет `images.yaml` прямо в `main` (`notify.yml`). Число одобрений — `REQUIRED_APPROVALS=0 bash scripts/apply_repo_settings.sh --apply` |
| Secret scanning + push protection | все | Токен не попадает в историю даже случайно |
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

## rt-ui → frontend: переход с ручного tarball на реестр

Сейчас `frontend` тянет дизайн-систему как `file:./vendor/lct-testkit-rt-ui-0.1.0.tgz`, который кто-то вручную кладёт в
release `vendor-assets` (`frontend/.github/scripts/restore-vendor.sh`). Версии при этом расходятся молча: в `rt-ui` уже
есть изменения поверх 0.1.0, а хэш tarball во `frontend/pnpm-lock.yaml` — от старой сборки (локальная сборка `rt-ui` даёт
другой хэш, и `pnpm install --frozen-lockfile` падает по `ERR_PNPM_TARBALL_INTEGRITY`).

`rt-ui` теперь умеет публиковаться приватным npm-пакетом `@lct-testkit/rt-ui` в GitHub Packages (`rt-ui/.github/workflows/release.yml`
по тегу `vX.Y.Z`). **Переключать `frontend` можно только ПОСЛЕ первого релиза** — иначе его сборка сломается. Порядок:

1. `rt-ui`: перенести содержимое `[Unreleased]` в `CHANGELOG.md` под новую версию (например `## [0.1.1] — <дата>`), поднять `version` в `package.json`, `git tag v0.1.1 && git push --tags`. Дождаться зелёного релиза.
2. Пакет `@lct-testkit/rt-ui` → Package settings → «Manage Actions access» → добавить репозиторий `frontend` (Read).
3. `frontend`, `.npmrc`:
   ```
   engine-strict=true
   @lct-testkit:registry=https://npm.pkg.github.com
   //npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
   ```
4. `frontend`: `.npmrc` требует переменную `NODE_AUTH_TOKEN` при ЛЮБОМ `pnpm install` (без неё pnpm падает «Failed to replace env in config»), локально — `export NODE_AUTH_TOKEN=<classic PAT read:packages>`. Затем `pnpm add @lct-testkit/rt-ui@0.1.1` (обновит `package.json` и `pnpm-lock.yaml`); удалить `vendor/`, `.github/scripts/restore-vendor.sh`, `fs.allow: ['../rt-ui']` в `vite.config.ts`, release `vendor-assets`.
5. `frontend/.github/workflows/ci.yml`: в jobs `check`/`contract` убрать шаг «Восстановить vendor/», на шаг `pnpm install` добавить `env: NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`, а в `permissions` job'ов — `packages: read`. В job `publish` убрать `prepare-script` и вместо `secrets: inherit` передать секреты явно (PAT не нужен — достаточно, что пакету выдан доступ репозиторию `frontend`, п.2):
   ```yaml
       secrets:
         DEPLOY_DISPATCH_TOKEN: ${{ secrets.DEPLOY_DISPATCH_TOKEN }}
         NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```
6. `frontend/Dockerfile`: `RUN --mount=type=secret,id=npm_token NODE_AUTH_TOKEN="$(cat /run/secrets/npm_token)" pnpm install --frozen-lockfile` (вместо `COPY vendor`); reusable-workflow `docker-publish.yml` уже передаёт секрет `npm_token` из `NODE_AUTH_TOKEN`.
7. Дальше Dependabot (`npm`) сам предлагает PR на новые версии `@lct-testkit/rt-ui`.

## Ручные шаги, которые остаются за владельцем

1. Применить настройки: `bash scripts/apply_repo_settings.sh --apply`.
2. Создать секреты из таблицы выше.
3. Удалить устаревшую ветку бота: `git push origin --delete bot/update-images-35271171079` (в `deploy`).
4. Выпустить релиз `rt-ui` и выполнить переход `frontend` на реестр — раздел выше.
5. Выбрать лицензию (`frontend/README.md` прямо говорит, что её нет).
