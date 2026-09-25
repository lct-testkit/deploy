#!/usr/bin/env bash
# Применяет изменение к images.yaml (и синхронно к charts/rtk-crm/values.yaml) и пушит его в main с ретраями.
#
#   scripts/apply_and_push.sh "<commit message>" <команда...>
#
# Команда идемпотентно правит images.yaml (например, update_image_refs.py).
# Если push отклонён (параллельный бот успел раньше), мы не делаем
# `git pull --rebase` с риском конфликта, а откатываемся на свежий origin/main
# и применяем команду заново — результат детерминирован и от порядка не
# зависит.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "использование: apply_and_push.sh <commit message> <команда...>" >&2
  exit 2
fi

msg="$1"
shift

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

max_attempts=6
for attempt in $(seq 1 "$max_attempts"); do
  "$@"
  python scripts/validate_images.py images.yaml

  if git diff --quiet -- images.yaml charts/rtk-crm/values.yaml; then
    echo "images.yaml не изменился — коммит не нужен"
    exit 0
  fi

  git add images.yaml charts/rtk-crm/values.yaml
  git commit -m "$msg"

  if git push origin HEAD:main; then
    echo "запушено с попытки ${attempt}"
    exit 0
  fi

  echo "::warning::push отклонён (попытка ${attempt}/${max_attempts}), синхронизируюсь с origin/main"
  git fetch origin main
  git reset --hard origin/main
  sleep $((RANDOM % 6 + 2))
done

echo "::error::не удалось запушить images.yaml за ${max_attempts} попыток" >&2
exit 1
