# Настройка GHCR — ручные шаги

Эти пункты выполняются в GitHub UI и на реальной VM. Автоматизировать их
из репозитория нельзя (нужны права владельца организации/PAT), поэтому
это чек-лист, а не скрипт.

## 1. PAT для VM (только pull)

1. GitHub → Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token.
2. Владелец — организация `lct-testkit`, срок действия — на своё
   усмотрение (рекомендуется не «No expiration»).
3. Права: **только** `read:packages` (Package: Read-only). Никаких прав
   на запись/push — это «robot-аккаунт только на pull»: утечёт — пушить
   образы им нельзя.
4. На VM под пользователем `deploy` (создан `scripts/provision_vm.sh`):
   ```bash
   docker login ghcr.io -u <github-user> -p <PAT>
   ```
   Сохранит креды в `~/.docker/config.json` пользователя `deploy`.
5. Тот же PAT (или второй такой же — токен один раз показывается при
   создании, если старый уже не скопирован, проще сделать новый) нужен
   ещё и `.github/workflows/release.yml` этого репозитория — секретом
   `GHCR_PULL_TOKEN` (Settings → Secrets and variables → Actions → New
   repository secret, в `deploy`). Без него сборка офлайн-бандла падает
   на первом же `docker pull ghcr.io/lct-testkit/api` с `denied`:
   `GITHUB_TOKEN` workflow'а `deploy` не видит пакеты, опубликованные из
   `backend`/`frontend` — GHCR так и работает, кросс-репо пакеты по
   умолчанию недоступны `GITHUB_TOKEN`'у другого репозитория даже внутри
   одной организации (в отличие от пуша в свой же пакет — см. п.3).

## 2. Retention-политика пакетов

Для каждого пакета в `ghcr.io/lct-testkit/*` (Package settings →
Manage retention policy):
- держать последние **10** тегов;
- дополнительно держать всё, что соответствует семверу (`vX.Y.Z`), —
  чтобы релизные теги не вычищались по возрасту.

## 3. Права CI на push

Пуш образов (`build.yml`) выполняется под `GITHUB_TOKEN` самого workflow
с `permissions: packages: write` в этом workflow — отдельный секрет для
пуша не нужен, только для pull на VM (см. п.1).

## 4. `DEPLOY_DISPATCH_TOKEN` — уведомление deploy о новом образе

Без него `backend`/`frontend` соберут и запушат образ, но шаг «Уведомить
deploy» молча пропустится (`::warning::` в логе, джоб не падает) —
`images.yaml` в `deploy` не обновится, и autodeploy/`render_env_images.py`
продолжит смотреть на старый тег.

1. GitHub → Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token.
2. Владелец — организация `lct-testkit`, доступ — **только репозиторий
   `deploy`** (Repository access → Only select repositories).
3. Права: `Contents: Read and write` — `POST /repos/.../dispatches`
   (repository_dispatch) требует именно её; `read:packages` из п.1 тут не
   подходит, это про пакеты, а не про API репозитория.
4. Добавить один и тот же токен секретом **в оба** репозитория:
   `backend` → Settings → Secrets and variables → Actions → New repository
   secret → имя `DEPLOY_DISPATCH_TOKEN`; то же самое в `frontend`.
5. Проверка — `workflow_dispatch` любого из `build.yml` (Actions → build →
   Run workflow) или обычный push: шаг «Уведомить deploy» должен пройти
   без `::warning::`, а в `deploy` появиться коммит `chore(images): ...`.
