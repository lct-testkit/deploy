#!/usr/bin/env bash
# Автодеплой окружения на VM: подтягивает images.yaml из git, выкатывает новые
# образы с бэкапом «до» и health-gate «после», при неудаче откатывает образы.
#
# Pull-based, не push-based: CI НЕ ходит на VM по SSH (в GitHub нет такого
# секрета, на VM только read:packages PAT). VM сама, по расписанию (см.
# scripts/install_autodeploy.sh), приходит за новым состоянием. Идемпотентен:
# при неизменившемся images.yaml ничего не делает.
#
#   scripts/deploy.sh                      # RTK_ENV=demo (по умолчанию)
#   RTK_ENV=dev scripts/deploy.sh          # окружение dev
#   scripts/deploy.sh --init [--profile prod] [--host crm.example.local] [--tls acme|internal|off] [--fonts <каталог>]
#                            [--port-offset 100]
#                                          # первый запуск: сгенерировать секреты и runtime/
#   scripts/deploy.sh rollback             # вернуть образы предыдущего успешного деплоя
#
# Состояние окружения — /srv/rtk-<env>/ (STATE_DIR): .env, runtime/, .env.images,
# .env.images.prev, backups/. compose-проект называется rtk-<env>, поэтому dev/demo/
# prod на одной машине не пересекаются (порты разводит --port-offset при --init).
#
# ВАЖНО: миграции Alembic идут только вперёд. Откат образов не откатывает схему БД;
# если новая ревизия успела применить необратимые миграции, восстановление — из бэкапа,
# снятого перед выкладкой (путь печатается), командой scripts/restore_test.sh (проверка)
# и ручным pg_restore в боевую БД по RUNBOOK.md.
set -euo pipefail

RTK_ENV="${RTK_ENV:-demo}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-/srv/rtk-${RTK_ENV}}"
PROJECT="rtk-${RTK_ENV}"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
ENV_FILE="${STATE_DIR}/.env"
IMAGES_ENV="${STATE_DIR}/.env.images"
IMAGES_PREV="${STATE_DIR}/.env.images.prev"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
dc() { docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --env-file "$1" "${@:2}"; }

MODE="deploy"
INIT_ARGS=()
NO_PULL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    rollback) MODE="rollback"; shift ;;
    --init) MODE="init"; shift ;;
    --no-pull) NO_PULL=1; shift ;;
    --profile|--host|--port-offset|--tls|--fonts) INIT_ARGS+=("$1" "$2"); shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

if [[ "${MODE}" == "init" ]]; then
  mkdir -p "${STATE_DIR}"
  if [[ "${RTK_ENV}" == "prod" && ! " ${INIT_ARGS[*]} " =~ " --profile " ]]; then INIT_ARGS+=(--profile prod); fi
  bash "${REPO_DIR}/scripts/gen_env.sh" --dir "${REPO_DIR}/compose" --state-dir "${STATE_DIR}" "${INIT_ARGS[@]}"
  log "окружение ${RTK_ENV} инициализировано в ${STATE_DIR}; запустите scripts/deploy.sh"
  exit 0
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "нет ${ENV_FILE} — выполните: RTK_ENV=${RTK_ENV} scripts/deploy.sh --init (см. RUNBOOK.md «Первый деплой на VM»)" >&2
  exit 1
fi

# Прод не стартует с демо-секретами (в realm/s3.json они зашиты публично).
if [[ "${RTK_ENV}" == "prod" ]] && grep -qE "^(KEYCLOAK_CLIENT_SECRET=crm-bff-secret|SIGNATURE_SERVER_SECRET=change-me-in-prod|S3_SECRET_KEY=crm_secret_key)" "${ENV_FILE}"; then
  echo "ОТКАЗ: в ${ENV_FILE} демо-секреты. Для prod выполните --init (генерирует секреты)." >&2
  exit 1
fi

apply_images() {
  local images_env="$1"
  log "docker compose pull"
  dc "${images_env}" pull
  log "docker compose up -d --wait (пересоздаст только изменившиеся контейнеры)"
  dc "${images_env}" up -d --wait --wait-timeout 300 --remove-orphans
}

healthy() {
  local http_port
  http_port="$(grep -E '^HTTP_PORT=' "${ENV_FILE}" | tail -1 | cut -d= -f2)"
  bash "${REPO_DIR}/scripts/smoke.sh" "http://localhost:${http_port:-8080}" --timeout 180
}

if [[ "${MODE}" == "rollback" ]]; then
  [[ -f "${IMAGES_PREV}" ]] || { echo "нет ${IMAGES_PREV} — откатываться не к чему" >&2; exit 1; }
  log "откат: ${IMAGES_PREV} -> ${IMAGES_ENV}"
  cp "${IMAGES_ENV}" "${IMAGES_ENV}.rolled-back"
  cp "${IMAGES_PREV}" "${IMAGES_ENV}"
  apply_images "${IMAGES_ENV}"
  healthy
  log "откат выполнен"
  exit 0
fi

if [[ "${NO_PULL}" != 1 ]]; then
  log "git pull (${REPO_DIR})"
  git -C "${REPO_DIR}" pull --ff-only
fi

NEW_ENV="$(mktemp)"
trap 'rm -f "${NEW_ENV}"' EXIT
"$PY" "${REPO_DIR}/scripts/render_env_images.py" "${REPO_DIR}/images.yaml" > "${NEW_ENV}"

if [[ -f "${IMAGES_ENV}" ]] && cmp -s "${NEW_ENV}" "${IMAGES_ENV}"; then
  log "образы не изменились — деплой не требуется"
  exit 0
fi

# Бэкап «до»: только если стек уже работает (первый деплой бэкапить нечего).
RUNNING_PG=""
if [[ -f "${IMAGES_ENV}" ]]; then
  RUNNING_PG="$(dc "${IMAGES_ENV}" ps --status running --quiet postgres 2>/dev/null || true)"
fi
if [[ -n "${RUNNING_PG}" ]]; then
  log "бэкап перед выкладкой"
  BACKUP_DIR="$(bash "${REPO_DIR}/scripts/backup.sh" --env-file "${ENV_FILE}" --images-env "${IMAGES_ENV}" \
                  --project "${PROJECT}" --compose "${COMPOSE_FILE}" --out "${STATE_DIR}/backups" | tail -1)"
  log "бэкап: ${BACKUP_DIR}"
  # Ротация: оставить последние KEEP_BACKUPS.
  # shellcheck disable=SC2012
  ls -1dt "${STATE_DIR}/backups"/*/ 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -rf
else
  log "стек не запущен — бэкап пропущен (первый деплой)"
fi

[[ -f "${IMAGES_ENV}" ]] && cp "${IMAGES_ENV}" "${IMAGES_PREV}"
cp "${NEW_ENV}" "${IMAGES_ENV}"

if apply_images "${IMAGES_ENV}" && healthy; then
  log "готово: $(dc "${IMAGES_ENV}" ps --format '{{.Name}}: {{.Status}}' | tr '\n' ';')"
  exit 0
fi

log "ОШИБКА выкладки — откатываю образы на предыдущие"
if [[ -f "${IMAGES_PREV}" ]]; then
  cp "${IMAGES_ENV}" "${IMAGES_ENV}.failed"
  cp "${IMAGES_PREV}" "${IMAGES_ENV}"
  apply_images "${IMAGES_ENV}" || true
  healthy || log "ВНИМАНИЕ: после отката система тоже нездорова — нужно ручное вмешательство (RUNBOOK.md)"
fi
echo "выкладка провалена; проваленные ссылки на образы: ${IMAGES_ENV}.failed; бэкап перед выкладкой: ${BACKUP_DIR:-нет}" >&2
exit 1
