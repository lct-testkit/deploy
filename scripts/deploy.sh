#!/usr/bin/env bash
# Автодеплой rtk-demo (Фаза 6, продолжение provision_vm.sh): подтягивает
# новый images.yaml из git, вычисляет актуальные теги образов, пуллит и
# перезапускает только то, что реально изменилось.
#
# Pull-based, не push-based: CI backend/frontend НЕ ходит на VM по SSH (нет
# такого секрета в GitHub вообще, см. docs/ghcr-setup.md — на VM только
# read:packages PAT). VM сама, по расписанию (см. scripts/install_autodeploy.sh),
# приходит за новым состоянием. Идемпотентен: `docker compose up -d` на
# неизменившихся образах — no-op, безопасно гонять хоть каждую минуту.
#
# Запускать из корня чекаута deploy-репозитория на VM:
#   scripts/deploy.sh                    # rtk-demo (по умолчанию)
#   RTK_ENV=dev scripts/deploy.sh         # rtk-dev
set -euo pipefail

RTK_ENV="${RTK_ENV:-demo}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="/srv/rtk-${RTK_ENV}"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
ENV_FILE="${PROJECT_DIR}/.env"
IMAGES_ENV_FILE="${PROJECT_DIR}/.env.images"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "нет ${ENV_FILE} — см. RUNBOOK.md «Первый деплой на VM», это разовая ручная настройка" >&2
  exit 1
fi

log "git pull (deploy-репозиторий, ${REPO_DIR})"
git -C "${REPO_DIR}" pull --ff-only

log "images.yaml -> ${IMAGES_ENV_FILE}"
python3 "${REPO_DIR}/scripts/render_env_images.py" "${REPO_DIR}/images.yaml" > "${IMAGES_ENV_FILE}"

log "docker compose pull"
docker compose \
  -f "${COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --env-file "${IMAGES_ENV_FILE}" \
  --project-directory "${PROJECT_DIR}" \
  pull

log "docker compose up -d (пересоздаст только изменившиеся контейнеры)"
docker compose \
  -f "${COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --env-file "${IMAGES_ENV_FILE}" \
  --project-directory "${PROJECT_DIR}" \
  up -d --remove-orphans

log "готово: $(docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV_FILE}" --project-directory "${PROJECT_DIR}" ps --format '{{.Name}}: {{.Status}}' | tr '\n' '; ')"
