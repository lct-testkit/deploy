#!/usr/bin/env bash
# Сквозная проверка стека из образов images.yaml: поднять с нуля, прогнать smoke,
# (опционально) снять бэкап и проверить восстановление, убрать за собой.
#
#   bash scripts/e2e_stack.sh [--images-env <файл>] [--with-restore] [--keep]
#
# По умолчанию ссылки на образы берутся из images.yaml (режим digest) и требуют
# `docker login ghcr.io` — api/web в GHCR приватные. Секреты каждый раз новые
# (gen_env.sh), изолированный compose-проект rtk-e2e, порты 28080/28443/28333/25433.
#
# При падении печатает хвосты логов сервисов — по ним видно причину без
# повторного прогона.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
PROJECT="rtk-e2e"
IMAGES_ENV_SRC=""
WITH_RESTORE=0
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --images-env) IMAGES_ENV_SRC="$2"; shift 2 ;;
    --with-restore) WITH_RESTORE=1; shift ;;
    --keep) KEEP=1; shift ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

# `pwd -W` — путь в виде C:/… для нативного docker.exe при запуске из Git Bash на Windows; на Linux не нужен.
WORK="$(cd "$(mktemp -d)" && { pwd -W 2>/dev/null || pwd; })"
export HTTP_PORT=28080 HTTPS_PORT=28443 S3_PROXY_PORT=28333 POSTGRES_PORT=25433 REGISTRY_PORT=25000

dc() { docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${WORK}/.env" --env-file "${WORK}/.env.images" "$@"; }

cleanup() {
  local rc=$?
  if [[ ${rc} -ne 0 && -f "${WORK}/.env.images" ]]; then
    echo "::group::логи сервисов (последние 60 строк)"
    dc ps -a || true
    dc logs --no-color --tail 60 || true
    echo "::endgroup::"
  fi
  if [[ "${KEEP}" != 1 ]]; then
    dc down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "${WORK}"
  else
    echo "стенд оставлен: проект ${PROJECT}, каталог ${WORK}"
  fi
  exit ${rc}
}
trap cleanup EXIT

echo "[e2e] секреты и конфиги"
bash "${SCRIPT_DIR}/gen_env.sh" --dir "${REPO_DIR}/compose" --state-dir "${WORK}" --profile demo >/dev/null

if [[ -n "${IMAGES_ENV_SRC}" ]]; then
  cp "${IMAGES_ENV_SRC}" "${WORK}/.env.images"
else
  "$PY" "${SCRIPT_DIR}/render_env_images.py" "${REPO_DIR}/images.yaml" > "${WORK}/.env.images"
fi

echo "[e2e] docker compose up (образы: $(grep -c '_IMAGE=' "${WORK}/.env.images"))"
dc up -d --wait --wait-timeout 420

echo "[e2e] smoke"
bash "${SCRIPT_DIR}/smoke.sh" "http://localhost:${HTTP_PORT}" --timeout 180

if [[ "${WITH_RESTORE}" == 1 ]]; then
  echo "[e2e] бэкап"
  BACKUP="$(bash "${SCRIPT_DIR}/backup.sh" --env-file "${WORK}/.env" --images-env "${WORK}/.env.images" \
              --project "${PROJECT}" --compose "${COMPOSE_FILE}" --out "${WORK}/backups" | tail -1)"
  echo "[e2e] проверка восстановления"
  bash "${SCRIPT_DIR}/restore_test.sh" --backup "${BACKUP}" --env-file "${WORK}/.env" \
       --images-env "${WORK}/.env.images" --compose "${COMPOSE_FILE}"
fi

echo "[e2e] ВСЁ ЗЕЛЁНОЕ"
