#!/usr/bin/env bash
# Генерирует боевые секреты и согласованные с ними runtime-конфиги.
#
#   bash scripts/gen_env.sh [--dir compose] [--state-dir <каталог>] [--profile demo|prod]
#                           [--host <имя/IP>] [--tls off|internal|acme] [--fonts <каталог>]
#                           [--port-offset N] [--force]
#
#   --tls    off (по умолчанию): локальный стенд, http://ХОСТ:8080 и https://ХОСТ:8443 с самоподписанным сертификатом;
#            internal: HTTPS на 443 с самоподписанным сертификатом Caddy (закрытый контур, IP, внутренние имена);
#            acme: HTTPS на 443 с сертификатом Let's Encrypt (публичный домен, DNS на этот сервер, порты 80/443 из интернета).
#            internal и acme требуют --host и несовместимы с --port-offset (порты 80/443/8333 фиксированы).
#   --fonts  каталог с *.woff шрифтов Rostelecom Basis (лицензионные, в образ web не входят): копируются в runtime/fonts.
#
# Читает шаблоны из --dir (по умолчанию compose/ рядом со скриптом) и создаёт в
# --state-dir (по умолчанию = --dir; на VM — /srv/rtk-<env>):
#   .env                              — из .env.example, секреты заменены случайными, порты/URL/TLS по --host и --tls
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
# Зависимости: только bash, sed, tr, head, base64 (coreutils; никакого python/openssl — скрипт
# ездит в офлайн-бандле на минимальные серверы).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib_host.sh
source "${SCRIPT_DIR}/lib_host.sh"
TARGET_DIR="${SCRIPT_DIR}/../compose"
STATE_DIR=""
PROFILE="demo"
HOST=""
TLS_MODE="off"
FONTS_SRC=""
PORT_OFFSET=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --tls) TLS_MODE="$2"; shift 2 ;;
    --fonts) FONTS_SRC="$2"; shift 2 ;;
    --port-offset) PORT_OFFSET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

case "${PROFILE}" in demo|prod) ;; *) echo "--profile: demo|prod" >&2; exit 2 ;; esac
case "${PORT_OFFSET}" in ''|*[!0-9]*) echo "--port-offset: нужно неотрицательное целое" >&2; exit 2 ;; esac
rtk_check_mode "${TLS_MODE}" "${HOST}" "${PORT_OFFSET}" || exit 2
if [[ -n "${FONTS_SRC}" ]]; then
  [[ -d "${FONTS_SRC}" ]] || { echo "--fonts: нет каталога ${FONTS_SRC}" >&2; exit 2; }
  compgen -G "${FONTS_SRC}/*.woff*" >/dev/null || { echo "--fonts: в ${FONTS_SRC} нет *.woff/*.woff2" >&2; exit 2; }
fi

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

# Ключ Fernet (SETTINGS_ENCRYPTION_KEY): 32 случайных байта в url-safe base64 (44 знака, `=` на конце). Только
# coreutils: на целевой машине нет ни python, ни openssl.
fernet_key() {
  (set +o pipefail; head -c 32 /dev/urandom | base64 | tr -d '
' | tr '+/' '-_')
}

POSTGRES_PASSWORD="$(rand 32)"
CRM_APP_PASSWORD="$(rand 32)"
KEYCLOAK_ADMIN_PASSWORD="$(rand 24)"
KEYCLOAK_CLIENT_SECRET="$(rand 40)"
KEYCLOAK_ADMIN_CLIENT_SECRET="$(rand 40)"
SIGNATURE_SERVER_SECRET="$(rand 48)"
AUDIT_HMAC_KEY="$(rand 48)"
SETTINGS_ENCRYPTION_KEY="$(fernet_key)"
S3_ACCESS_KEY="$(rand 20)"
S3_SECRET_KEY="$(rand 40)"
S3_SIGN_ACCESS_KEY="$(rand 20)"
S3_SIGN_SECRET_KEY="$(rand 40)"
CMS_WEBHOOK_SECRET="$(rand 40)"

cp "${EXAMPLE}" "${ENV_FILE}"

# set_var KEY VALUE — заменяет `KEY=...`; если ключа нет — дописывает.
set_var() { rtk_env_set "${ENV_FILE}" "$1" "$2"; }

set_var APP_PROFILE "${PROFILE}"
set_var POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
set_var CRM_APP_PASSWORD "${CRM_APP_PASSWORD}"
set_var KEYCLOAK_ADMIN_PASSWORD "${KEYCLOAK_ADMIN_PASSWORD}"
set_var KEYCLOAK_CLIENT_SECRET "${KEYCLOAK_CLIENT_SECRET}"
set_var KEYCLOAK_ADMIN_CLIENT_SECRET "${KEYCLOAK_ADMIN_CLIENT_SECRET}"
set_var SIGNATURE_SERVER_SECRET "${SIGNATURE_SERVER_SECRET}"
set_var AUDIT_HMAC_KEY "${AUDIT_HMAC_KEY}"
set_var SETTINGS_ENCRYPTION_KEY "${SETTINGS_ENCRYPTION_KEY}"
set_var S3_ACCESS_KEY "${S3_ACCESS_KEY}"
set_var S3_SECRET_KEY "${S3_SECRET_KEY}"
set_var CMS_WEBHOOK_SECRET "${CMS_WEBHOOK_SECRET}"
[[ "${PROFILE}" == "prod" ]] && set_var APP_MODE prod

# Порты, адреса и TLS-переменные Caddy по режиму (--tls) и хосту. В режиме off несколько окружений на одной
# машине (dev/demo/prod) различаются смещением портов.
rtk_apply_mode_env "${ENV_FILE}" "${TLS_MODE}" "${HOST}" "${PORT_OFFSET}"

# --- runtime-конфиги с теми же секретами ---------------------------------------
mkdir -p "${RUNTIME}/keycloak" "${RUNTIME}/seaweedfs"

rtk_render_realm "${TARGET_DIR}/keycloak/realm-crm.json" "${RUNTIME}/keycloak/realm-crm.json" \
  "${KEYCLOAK_CLIENT_SECRET}" "${KEYCLOAK_ADMIN_CLIENT_SECRET}" "${TLS_MODE}" "${HOST}" "${RTK_HTTP_PORT}" "${RTK_HTTPS_PORT}"

sed \
  -e "s|crm_sign_access|${S3_SIGN_ACCESS_KEY}|g" \
  -e "s|crm_sign_secret_key|${S3_SIGN_SECRET_KEY}|g" \
  -e "s|crm_access|${S3_ACCESS_KEY}|g" \
  -e "s|crm_secret_key|${S3_SECRET_KEY}|g" \
  "${TARGET_DIR}/seaweedfs/s3.json" > "${RUNTIME}/seaweedfs/s3.json"

# Абсолютные пути: не зависят от того, откуда запущен compose.
set_var SEAWEED_S3_CONFIG "${RUNTIME}/seaweedfs/s3.json"
set_var KEYCLOAK_IMPORT_DIR "${RUNTIME}/keycloak"

# Шрифты: лицензионные, в git и образ web не входят. Без --fonts compose берёт пустой ./fonts.
if [[ -n "${FONTS_SRC}" ]]; then
  mkdir -p "${RUNTIME}/fonts"
  cp "${FONTS_SRC}"/*.woff* "${RUNTIME}/fonts/"
  chmod 755 "${RUNTIME}/fonts"
  chmod 644 "${RUNTIME}/fonts/"*
  set_var FONTS_DIR "${RUNTIME}/fonts"
fi

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

echo "готово (режим TLS: ${TLS_MODE}, адрес: ${RTK_BASE_URL}):"
echo "  ${ENV_FILE}"
echo "  ${RUNTIME}/keycloak/realm-crm.json"
echo "  ${RUNTIME}/seaweedfs/s3.json"
echo
echo "ВНИМАНИЕ: демо-пользователи realm (Admin12345678!, Kam123456789!, …) остались."
echo "Удалите их или смените пароли в консоли Keycloak до открытия доступа извне."
echo "Пароль администратора Keycloak сохранён в ${ENV_FILE} (KEYCLOAK_ADMIN_PASSWORD)."
