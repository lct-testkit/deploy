#!/usr/bin/env bash
# Резервная копия стека: PostgreSQL (crm + keycloak), том SeaweedFS,
# контрольные суммы и счётчики строк (эталон для restore_test.sh).
#
#   bash scripts/backup.sh --env-file <.env> --images-env <.env.images> [--project rtk-crm]
#                          [--compose compose/docker-compose.yml] [--out ./backups]
#
# Непроверенный бэкап не существует (спека §6): результат этого скрипта
# проверяет scripts/restore_test.sh — оба гоняются в CI. В stdout последней
# строкой печатается путь к каталогу бэкапа.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../compose/docker-compose.yml"
ENV_FILE=""
IMAGES_ENV=""
PROJECT="rtk-crm"
OUT_BASE="./backups"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --images-env) IMAGES_ENV="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    --out) OUT_BASE="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
[[ -f "${ENV_FILE}" && -f "${IMAGES_ENV}" ]] || { echo "нужны --env-file и --images-env" >&2; exit 2; }

dc() { docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV}" "$@"; }
env_val() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2- || true; }

PG_USER="$(env_val POSTGRES_USER "${ENV_FILE}")"; PG_USER="${PG_USER:-crm}"
PG_DB="$(env_val POSTGRES_DB "${ENV_FILE}")"; PG_DB="${PG_DB:-crm}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_BASE}/${PROJECT}-${STAMP}"
mkdir -p "${OUT}"
# `pwd -W` и MSYS_NO_PATHCONV — только для запуска из Git Bash на Windows (нативный docker.exe
# иначе искажает пути вида /backup); на Linux оба ни на что не влияют.
OUT="$(cd "${OUT}" && { pwd -W 2>/dev/null || pwd; })"
export MSYS_NO_PATHCONV=1

echo "[backup] ${PROJECT} -> ${OUT}" >&2

# Счётчики строк по всем таблицам public — НИЖНЯЯ граница для restore_test.sh.
# Снимаются ДО дампа: на живой системе (аудит, очереди) строк за время дампа может
# стать больше, но не меньше — поэтому после восстановления требуется count >= эталон.
echo "[backup] счётчики строк" >&2
dc exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -At -F $'\t' -c "
  SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  ORDER BY 1" > "${OUT}/counts.tsv"

# Роли кластера (crm_app и т.п.) в pg_dump отдельных баз НЕ попадают: без них
# GRANT'ы при восстановлении падают. Файл содержит хэши паролей — права 600.
echo "[backup] роли кластера (pg_dumpall --roles-only)" >&2
dc exec -T postgres pg_dumpall -U "${PG_USER}" --roles-only > "${OUT}/globals.sql"
chmod 600 "${OUT}/globals.sql"

echo "[backup] pg_dump ${PG_DB}" >&2
dc exec -T postgres pg_dump -U "${PG_USER}" -Fc "${PG_DB}" > "${OUT}/${PG_DB}.dump"
echo "[backup] pg_dump keycloak (realm и пользователи)" >&2
dc exec -T postgres pg_dump -U "${PG_USER}" -Fc keycloak > "${OUT}/keycloak.dump"

echo "[backup] том SeaweedFS" >&2
SEAWEED_IMAGE="$(env_val SEAWEEDFS_IMAGE "${IMAGES_ENV}")"
[[ -n "${SEAWEED_IMAGE}" ]] || { echo "SEAWEEDFS_IMAGE не найден в ${IMAGES_ENV}" >&2; exit 1; }
docker run --rm --entrypoint tar -v "${PROJECT}_seaweed_data:/data:ro" -v "${OUT}:/backup" \
  "${SEAWEED_IMAGE}" czf /backup/seaweed_data.tgz -C /data .

( cd "${OUT}" && sha256sum ./*.dump ./*.tgz ./*.sql ./counts.tsv > SHA256SUMS )
echo "[backup] готово: $(du -sh "${OUT}" | cut -f1)" >&2
echo "${OUT}"
