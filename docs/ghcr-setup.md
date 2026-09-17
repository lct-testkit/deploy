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

## 2. Retention-политика пакетов

Для каждого пакета в `ghcr.io/lct-testkit/*` (Package settings →
Manage retention policy):
- держать последние **10** тегов;
- дополнительно держать всё, что соответствует семверу (`vX.Y.Z`), —
  чтобы релизные теги не вычищались по возрасту.

## 3. Права CI на push

Пуш образов (`build.yml`, Фаза 3) выполняется под `GITHUB_TOKEN` самого
workflow с `permissions: packages: write` в этом workflow — отдельный
секрет для пуша не нужен, только для pull на VM (см. п.1).
