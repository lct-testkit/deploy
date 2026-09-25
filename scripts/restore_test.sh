#!/usr/bin/env bash
# Проверка восстановления (спека §6, «make restore-test»): поднимает ЧИСТЫЙ
# изолированный стенд из бэкапа и убеждается, что данные на месте, а система
# работает. Непроверенный бэкап не существует.
#
#   bash scripts/restore_test.sh --backup <каталог бэкапа> --env-file <.env> --images-env <.env.images>
#                                [--compose compose/docker-compose.yml] [--keep]
#
# Стенд поднимается отдельным compose-проектом rtk-restore-test на других портах
# (18080/18443/18333/15433) и удаляется вместе с томами (--keep оставляет его).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../compose/docker-compose.yml"
BACKUP=""; ENV_FILE=""; IMAGES_ENV=""; KEEP=0
PROJECT="rtk-restore-test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --images-env) IMAGES_ENV="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
[[ -d "${BACKUP}" && -f "${ENV_FILE}" && -f "${IMAGES_ENV}" ]] || { echo "нужны --backup, --env-file, --images-env" >&2; exit 2; }

BACKUP="$(cd "${BACKUP}" && pwd)"
env_val() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true; }
PG_USER="$(env_val POSTGRES_USER)"; PG_USER="${PG_USER:-crm}"
PG_DB="$(env_val POSTGRES_DB)"; PG_DB="${PG_DB:-crm}"

# Изоляция от боевого стенда: порты и проект. Переменные окружения процесса
# имеют приоритет над --env-file.
export HTTP_PORT=18080 HTTPS_PORT=18443 S3_PROXY_PORT=18333 POSTGRES_PORT=15433 REGISTRY_PORT=15000
dc() { docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV}" "$@"; }
cleanup() { if [[ "${KEEP}" != 1 ]]; then dc down -v --remove-orphans >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

echo "[restore-test] 1/5 контрольные суммы бэкапа"
( cd "${BACKUP}" && sha256sum --quiet -c SHA256SUMS )

echo "[restore-test] 2/5 чистый postgres"
dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d --wait postgres

echo "[restore-test] 3/5 восстановление баз"
psql_admin() { dc exec -T postgres psql -U "${PG_USER}" -d postgres -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
psql_admin "DROP DATABASE IF EXISTS \"${PG_DB}\""
psql_admin "DROP DATABASE IF EXISTS keycloak"
psql_admin "CREATE DATABASE \"${PG_DB}\""
psql_admin "CREATE DATABASE keycloak"
# Роли кластера (crm_app и др.): "already exists" для суперпользователя — норма, поэтому без ON_ERROR_STOP.
dc exec -T postgres psql -U "${PG_USER}" -d postgres < "${BACKUP}/globals.sql" >/dev/null 2>&1 || true
# --no-owner: роль приложения создаёт миграция/инициализация; владельцем станет пользователь восстановления.
dc exec -T postgres pg_restore -U "${PG_USER}" -d "${PG_DB}" --no-owner < "${BACKUP}/${PG_DB}.dump"
dc exec -T postgres pg_restore -U "${PG_USER}" -d keycloak --no-owner < "${BACKUP}/keycloak.dump"

echo "[restore-test] 4/5 сверка счётчиков строк с эталоном бэкапа"
RESTORED="$(mktemp)"
dc exec -T postgres psql -U "${PG_USER}" -d "${PG_DB}" -At -F $'\t' -c "
  SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  ORDER BY 1" > "${RESTORED}"
# Нижняя граница: в восстановленной базе каждая таблица должна содержать не меньше
# строк, чем зафиксировано ДО дампа (см. backup.sh).
check_counts() {
  awk -F '\t' '
    NR == FNR { got[$1] = $2; next }
    {
      if (!($1 in got)) { print "нет таблицы " $1; bad = 1 }
      else if (got[$1] + 0 < $2 + 0) { print $1 ": было >= " $2 ", после восстановления " got[$1]; bad = 1 }
    }
    END { exit bad }
  ' "$1" "$2"
}
if ! check_counts "${RESTORED}" "${BACKUP}/counts.tsv"; then
  echo "[restore-test] ОШИБКА: данные после восстановления не совпадают с бэкапом" >&2
  exit 1
fi
echo "   таблиц: $(wc -l < "${RESTORED}"), строк во всех: $(awk -F '\t' '{s += $2} END {print s}' "${RESTORED}")"
rm -f "${RESTORED}"

echo "[restore-test] 5/5 весь стек поверх восстановленных данных + smoke"
dc up -d --wait --wait-timeout 300
bash "${SCRIPT_DIR}/smoke.sh" "http://localhost:${HTTP_PORT}" --timeout 240

echo "[restore-test] ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО: ${BACKUP}"
