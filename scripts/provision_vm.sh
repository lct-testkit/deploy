#!/usr/bin/env bash
# Подготовка VM под два независимых compose-проекта (Фаза 2, DEVOPS_PLAN.md):
#   rtk-dev  — отладочный стенд, ломается свободно
#   rtk-demo — живой стенд для стейкхолдеров, обновляется только автодеплоем
#
# Идемпотентный: повторный запуск не трогает то, что уже создано.
# Запускать руками на целевой VM с правами sudo:
#   sudo bash scripts/provision_vm.sh
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DIRS=(/srv/rtk-dev /srv/rtk-demo)
SWAPFILE="/swapfile"
SWAPSIZE_MB=2048

if [[ $EUID -ne 0 ]]; then
  echo "нужен root (sudo)" >&2
  exit 1
fi

echo "== docker / compose plugin =="
if ! command -v docker >/dev/null 2>&1; then
  echo "docker не найден — установите его вручную перед повторным запуском" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin не найден — установите его вручную перед повторным запуском" >&2
  exit 1
fi
echo "docker: $(docker --version)"
echo "compose: $(docker compose version --short)"

echo "== пользователь ${DEPLOY_USER} =="
if id "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "пользователь ${DEPLOY_USER} уже существует — пропуск"
else
  useradd --system --create-home --groups docker --shell /usr/sbin/nologin "${DEPLOY_USER}"
  echo "создан пользователь ${DEPLOY_USER} (в группе docker)"
fi

echo "== каталоги =="
for d in "${DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    echo "$d уже существует — пропуск"
  else
    mkdir -p "$d"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "$d"
    echo "создан $d"
  fi
done

echo "== swap ${SWAPSIZE_MB}MB =="
if swapon --show=NAME --noheadings | grep -q .; then
  echo "swap уже настроен — пропуск"
elif [[ -f "$SWAPFILE" ]]; then
  echo "$SWAPFILE уже существует, но не активен — включите его вручную (swapon), не трогаю"
else
  fallocate -l "${SWAPSIZE_MB}M" "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "$SWAPFILE" >> /etc/fstab
  echo "создан и включён swap ${SWAPSIZE_MB}MB, добавлен в /etc/fstab"
fi

cat <<EOF

Готово. Дальше руками (см. docs/ghcr-setup.md):
  1. создать PAT (read:packages) в GitHub;
  2. su - ${DEPLOY_USER} -c 'docker login ghcr.io -u <github-user> -p <PAT>'
EOF
