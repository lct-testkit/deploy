#!/usr/bin/env bash
# Генерирует боевые секреты и согласованные с ними runtime-конфиги.
#
#   bash scripts/gen_env.sh [--dir compose] [--state-dir <каталог>] [--profile demo|prod]
#                           [--host <имя/IP>] [--port-offset N] [--force]
#
# Читает шаблоны из --dir (по умолчанию compose/ рядом со скриптом) и создаёт в
# --state-dir (по умолчанию = --dir; на VM — /srv/rtk-<env>):
#   .env                              — из .env.example, секреты заменены случайными
#   runtime/keycloak/realm-crm.json   — демо-realm с теми же client secret'ами
#   runtime/seaweedfs/s3.json         — S3-ключи, совпадающие с .env
#
# Зачем runtime/: client secret'ы Keycloak и S3-ключи зашиты в демо-файлах
# (crm-bff-secret, crm_access, …). Замена значений только в .env приводила к
# рассинхрону — приложение и Keycloak/SeaweedFS переставали понимать друг
# друга. Здесь секрет подставляется во все три места сразу.
#
# Внимание: демо-ПОЛЬЗОВАТЕЛИ realm (Admin12345678! и т.п.) остаются — их
# нужно удалить или сменить пароли в консоли Keycloak до открытия доступа
# извне. Скрипт предупреждает об этом явно.
#
# Зависимости: только bash, sed, tr, head (никакого python/openssl — скрипт
# ездит в офлайн-бандле на минимальные серверы).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/../compose"
STATE_DIR=""
PROFILE="demo"
HOST=""
PORT_OFFSET=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port-offset) PORT_OFFSET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

case "${PROFILE}" in demo|prod) ;; *) echo "--profile: demo|prod" >&2; exit 2 ;; esac

# abspath: абсолютный путь. `pwd -W` (Git Bash на Windows) даёт C:/… — именно такой путь понимает
# нативный docker.exe для bind-mount'ов; на Linux `pwd -W` не существует и берётся обычный pwd.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

TARGET_DIR="$(abspath "${TARGET_DIR}")"
mkdir -p "${STATE_DIR:-${TARGET_DIR}}"
STATE_DIR="$(abspath "${STATE_DIR:-${TARGET_DIR}}")"
EXAMPLE="${TARGET_DIR}/.env.example"
ENV_FILE="${STATE_DIR}/.env"
RUNTIME="${STATE_DIR}/runtime"

[[ -f "${EXAMPLE}" ]] || { echo "нет ${EXAMPLE}" >&2; exit 1; }
if [[ -f "${ENV_FILE}" && "${FORCE}" != "1" ]]; then
  echo "${ENV_FILE} уже существует — не перезаписываю (используйте --force, секреты будут заменены новыми)" >&2
  exit 1
fi

# Случайная строка [A-Za-z0-9] заданной длины. pipefail отключаем локально:
# `head` закрывает канал раньше `tr`, и tr получает SIGPIPE (код 141).
rand() {
  (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1")
}

POSTGRES_PASSWORD="$(rand 32)"
CRM_APP_PASSWORD="$(rand 32)"
KEYCLOAK_ADMIN_PASSWORD="$(rand 24)"
KEYCLOAK_CLIENT_SECRET="$(rand 40)"
KEYCLOAK_ADMIN_CLIENT_SECRET="$(rand 40)"
SIGNATURE_SERVER_SECRET="$(rand 48)"
S3_ACCESS_KEY="$(rand 20)"
S3_SECRET_KEY="$(rand 40)"
S3_SIGN_ACCESS_KEY="$(rand 20)"
S3_SIGN_SECRET_KEY="$(rand 40)"
CMS_WEBHOOK_SECRET="$(rand 40)"

cp "${EXAMPLE}" "${ENV_FILE}"

# set_var KEY VALUE — заменяет `KEY=...`; если ключа нет — дописывает.
set_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

set_var APP_PROFILE "${PROFILE}"
set_var POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
set_var CRM_APP_PASSWORD "${CRM_APP_PASSWORD}"
set_var KEYCLOAK_ADMIN_PASSWORD "${KEYCLOAK_ADMIN_PASSWORD}"
set_var KEYCLOAK_CLIENT_SECRET "${KEYCLOAK_CLIENT_SECRET}"
set_var KEYCLOAK_ADMIN_CLIENT_SECRET "${KEYCLOAK_ADMIN_CLIENT_SECRET}"
set_var SIGNATURE_SERVER_SECRET "${SIGNATURE_SERVER_SECRET}"
set_var S3_ACCESS_KEY "${S3_ACCESS_KEY}"
set_var S3_SECRET_KEY "${S3_SECRET_KEY}"
set_var CMS_WEBHOOK_SECRET "${CMS_WEBHOOK_SECRET}"
[[ "${PROFILE}" == "prod" ]] && set_var APP_MODE prod

# Порты: несколько окружений на одной машине (dev/demo/prod) различаются смещением.
HTTP_PORT=$((8080 + PORT_OFFSET))
HTTPS_PORT=$((8443 + PORT_OFFSET))
S3_PORT=$((8333 + PORT_OFFSET))
PUBLIC_HOST="${HOST:-localhost}"
set_var HTTP_PORT "${HTTP_PORT}"
set_var HTTPS_PORT "${HTTPS_PORT}"
set_var S3_PROXY_PORT "${S3_PORT}"
set_var POSTGRES_PORT "$((5433 + PORT_OFFSET))"
set_var BASE_URL "http://${PUBLIC_HOST}:${HTTP_PORT}"
set_var KEYCLOAK_PUBLIC_URL "http://${PUBLIC_HOST}:${HTTP_PORT}/auth"
set_var S3_PUBLIC_ENDPOINT_URL "http://${PUBLIC_HOST}:${S3_PORT}"
[[ -n "${HOST}" ]] && set_var CRM_TLS_HOST "${HOST}"

# --- runtime-конфиги с теми же секретами ---------------------------------------
mkdir -p "${RUNTIME}/keycloak" "${RUNTIME}/seaweedfs"

sed \
  -e "s|crm-bff-secret|${KEYCLOAK_CLIENT_SECRET}|g" \
  -e "s|crm-admin-secret|${KEYCLOAK_ADMIN_CLIENT_SECRET}|g" \
  -e "s|//localhost:8080|//${PUBLIC_HOST}:${HTTP_PORT}|g" \
  -e "s|//localhost:8443|//${PUBLIC_HOST}:${HTTPS_PORT}|g" \
  "${TARGET_DIR}/keycloak/realm-crm.json" > "${RUNTIME}/keycloak/realm-crm.json"

sed \
  -e "s|crm_sign_access|${S3_SIGN_ACCESS_KEY}|g" \
  -e "s|crm_sign_secret_key|${S3_SIGN_SECRET_KEY}|g" \
  -e "s|crm_access|${S3_ACCESS_KEY}|g" \
  -e "s|crm_secret_key|${S3_SECRET_KEY}|g" \
  "${TARGET_DIR}/seaweedfs/s3.json" > "${RUNTIME}/seaweedfs/s3.json"

# Абсолютные пути: не зависят от того, откуда запущен compose.
set_var SEAWEED_S3_CONFIG "${RUNTIME}/seaweedfs/s3.json"
set_var KEYCLOAK_IMPORT_DIR "${RUNTIME}/keycloak"

# Права: .env читает только владелец. Файлы realm и s3.json монтируются в
# контейнеры, которые работают под другим UID (Keycloak — 1000), поэтому они
# 644; каталог runtime/ закрываем для посторонних (700 у самого каталога не
# годится по той же причине — 755, доступ ограничивает владелец родителя).
chmod 600 "${ENV_FILE}"
chmod 755 "${RUNTIME}" "${RUNTIME}/keycloak" "${RUNTIME}/seaweedfs"
chmod 644 "${RUNTIME}/keycloak/realm-crm.json" "${RUNTIME}/seaweedfs/s3.json"

# Самопроверка: демо-секретов в сгенерированных файлах остаться не должно.
if grep -qE "crm-bff-secret|crm-admin-secret|crm_secret_key|crm_access|change-me-in-prod" \
     "${ENV_FILE}" "${RUNTIME}/keycloak/realm-crm.json" "${RUNTIME}/seaweedfs/s3.json"; then
  echo "ОШИБКА: в сгенерированных файлах остались демо-секреты" >&2
  exit 1
fi

echo "готово:"
echo "  ${ENV_FILE}"
echo "  ${RUNTIME}/keycloak/realm-crm.json"
echo "  ${RUNTIME}/seaweedfs/s3.json"
echo
echo "ВНИМАНИЕ: демо-пользователи realm (Admin12345678!, Kam123456789!, …) остались."
echo "Удалите их или смените пароли в консоли Keycloak до открытия доступа извне."
echo "Пароль администратора Keycloak сохранён в ${ENV_FILE} (KEYCLOAK_ADMIN_PASSWORD)."
