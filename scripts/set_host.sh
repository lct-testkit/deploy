#!/usr/bin/env bash
# Меняет адрес и/или режим TLS УЖЕ УСТАНОВЛЕННОГО стенда, не переустанавливая его (секреты и данные остаются).
#
#   bash scripts/set_host.sh --host <имя/IP> [--tls off|internal|acme] [--env-file compose/.env]
#                            [--images-env compose/.env.images] [--compose FILE] [--project NAME] [--no-restart]
#
#   --host        новый адрес, по которому открывают систему
#   --tls         новый режим (по умолчанию остаётся текущий из .env): off | internal | acme, см. scripts/gen_env.sh
#   --env-file    .env стенда (для окружений deploy.sh: /srv/rtk-<env>/.env; --images-env и --project — оттуда же)
#   --no-restart  только переписать .env и realm, стек не трогать (команды для ручного применения будут напечатаны)
#
# Зачем отдельный скрипт. Realm Keycloak импортируется ОДИН РАЗ, при создании БД Keycloak; правка runtime/keycloak/realm-crm.json
# у установленного стенда ничего не меняет, и вход на новом домене падает с invalid_redirect_uri. Поэтому скрипт, кроме
# .env и файла realm, прописывает допустимые адреса клиента crm-bff прямо в БД Keycloak (redirect_uris, web_origins,
# post.logout.redirect.uris), затем пересоздаёт caddy/api/worker/web с новым окружением и перезапускает Keycloak (его кэш
# иначе не увидит правку БД). Старые адреса в списке допустимых остаются — при необходимости уберите их в консоли Keycloak.
#
# Не трогает: пароли, секреты, тома (БД, файлы, сертификаты Caddy). Перед правкой .env сохраняется копия .env.bak-<время>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib_host.sh
source "${SCRIPT_DIR}/lib_host.sh"

ENV_FILE="${REPO_DIR}/compose/.env"
IMAGES_ENV="${REPO_DIR}/compose/.env.images"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
PROJECT=""
HOST=""
NEW_MODE=""
RESTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --tls) NEW_MODE="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --images-env) IMAGES_ENV="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

die() { echo "set_host: $*" >&2; exit 1; }

[[ -n "${HOST}" ]] || { echo "нужен --host <имя или IP сервера>" >&2; exit 2; }
[[ -f "${ENV_FILE}" ]] || die "нет ${ENV_FILE} — стенд не установлен"
env_get() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true; }

CUR_MODE="$(env_get TLS_MODE)"; CUR_MODE="${CUR_MODE:-off}"
MODE="${NEW_MODE:-${CUR_MODE}}"

# Сдвиг портов нужен только режиму off; публичные режимы занимают фиксированные 80/443/8333.
OFFSET=0
if [[ "${MODE}" == off && "${CUR_MODE}" == off ]]; then
  cur_http="$(env_get HTTP_PORT)"
  [[ "${cur_http}" =~ ^[0-9]+$ ]] && OFFSET=$((cur_http - 8080))
fi
rtk_check_mode "${MODE}" "${HOST}" "${OFFSET}" || exit 2

proj_args=()
[[ -n "${PROJECT}" ]] && proj_args=(-p "${PROJECT}")
dc() {
  docker compose ${proj_args[@]+"${proj_args[@]}"} -f "${COMPOSE_FILE}" \
    --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV}" "$@"
}

PREV_BASE="$(env_get BASE_URL)"
BACKUP="${ENV_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "${ENV_FILE}" "${BACKUP}"
echo "set_host: копия .env -> ${BACKUP}"

# --- .env: порты, URL, TLS-переменные ------------------------------------------------------------------
rtk_apply_mode_env "${ENV_FILE}" "${MODE}" "${HOST}" "${OFFSET}"
echo "set_host: режим TLS ${CUR_MODE} -> ${MODE}, адрес ${PREV_BASE:-?} -> ${RTK_BASE_URL}"

# --- realm-файл (для новой БД Keycloak; у существующей его не читают) -------------------------------------
IMPORT_DIR="$(env_get KEYCLOAK_IMPORT_DIR)"
TEMPLATE="${REPO_DIR}/compose/keycloak/realm-crm.json"
if [[ -n "${IMPORT_DIR}" && -d "${IMPORT_DIR}" && -f "${TEMPLATE}" ]]; then
  rtk_render_realm "${TEMPLATE}" "${IMPORT_DIR}/realm-crm.json" \
    "$(env_get KEYCLOAK_CLIENT_SECRET)" "$(env_get KEYCLOAK_ADMIN_CLIENT_SECRET)" \
    "${MODE}" "${HOST}" "${RTK_HTTP_PORT}" "${RTK_HTTPS_PORT}"
  chmod 644 "${IMPORT_DIR}/realm-crm.json"
  echo "set_host: обновлён ${IMPORT_DIR}/realm-crm.json"
fi

# Допустимые адреса клиента crm-bff для нового режима.
if [[ "${MODE}" == off ]]; then
  REDIRECTS=("http://${HOST}:${RTK_HTTP_PORT}/*" "https://${HOST}:${RTK_HTTPS_PORT}/*")
  ORIGINS=("http://${HOST}:${RTK_HTTP_PORT}" "https://${HOST}:${RTK_HTTPS_PORT}")
else
  REDIRECTS=("https://${HOST}/*")
  ORIGINS=("https://${HOST}")
fi

if [[ "${RESTART}" == 0 ]]; then
  echo "set_host: --no-restart: стек не тронут. Чтобы применить:"
  echo "  1) добавить адреса клиента crm-bff в консоли Keycloak (Clients -> crm-bff): ${REDIRECTS[*]}"
  echo "  2) docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} --env-file ${IMAGES_ENV} up -d --wait"
  echo "  3) docker compose ... restart keycloak"
  exit 0
fi

# --- БД Keycloak: адреса клиента crm-bff -----------------------------------------------------------------
# "postgres запущен" — недостаточное условие: свою схему (таблицы client/redirect_uris/...) создаёт САМ
# Keycloak при первом старте (миграции Liquibase + импорт realm), и на холодном старте на медленном
# диске это может занять дольше, чем postgres становится healthy. Раньше здесь проверялось только
# "запущен ли postgres", и SQL ниже падал с `relation "redirect_uris" does not exist`, если Keycloak
# ещё не успел — не отличить от реальной ошибки. Ждём появления таблицы отдельно, до минуты.
PGUSER="$(env_get POSTGRES_USER)"; PGUSER="${PGUSER:-crm}"
SCHEMA_READY=""
if [[ -n "$(dc ps --status running --quiet postgres 2>/dev/null || true)" ]]; then
  for _ in $(seq 1 20); do
    if dc exec -T postgres psql -U "${PGUSER}" -d keycloak -tAc "SELECT 1 FROM client LIMIT 1" >/dev/null 2>&1; then
      SCHEMA_READY=1
      break
    fi
    sleep 3
  done
fi
if [[ -n "${SCHEMA_READY}" ]]; then
  sql="BEGIN;"
  bff="SELECT c.id FROM client c JOIN realm r ON r.id = c.realm_id WHERE r.name = 'crm' AND c.client_id = 'crm-bff'"
  for uri in "${REDIRECTS[@]}"; do
    sql+=" INSERT INTO redirect_uris (client_id, value) SELECT id, '${uri}' FROM (${bff}) b ON CONFLICT DO NOTHING;"
    sql+=" UPDATE client_attributes SET value = value || '##${uri}' WHERE name = 'post.logout.redirect.uris'"
    sql+=" AND client_id IN (${bff}) AND position('##${uri}##' in '##' || value || '##') = 0;"
  done
  for origin in "${ORIGINS[@]}"; do
    sql+=" INSERT INTO web_origins (client_id, value) SELECT id, '${origin}' FROM (${bff}) b ON CONFLICT DO NOTHING;"
  done
  sql+=" COMMIT;"
  if printf '%s\n' "${sql}" | dc exec -T postgres psql -U "${PGUSER}" -d keycloak -v ON_ERROR_STOP=1 -q >/dev/null; then
    echo "set_host: клиент crm-bff: допустимые адреса добавлены (${REDIRECTS[*]})"
  else
    # Не die(): .env и файл realm уже переписаны, и containers ниже всё равно пересоздаются с новым
    # окружением — обрыв здесь оставил бы стенд в перепутанном состоянии (.env на новый адрес,
    # контейнеры на старый). Вместо этого предупреждаем и продолжаем: адреса клиента добавить вручную
    # в консоли Keycloak (Clients -> crm-bff -> Valid redirect URIs), см. подсказку у --no-restart выше.
    echo "set_host: ПРЕДУПРЕЖДЕНИЕ: не удалось прописать адреса клиента crm-bff в БД Keycloak — добавьте вручную" \
         "в консоли Keycloak (Clients -> crm-bff): ${REDIRECTS[*]}. Установка продолжается, стек будет пересоздан." >&2
  fi
else
  echo "set_host: БД Keycloak не готова (postgres не запущен или Keycloak ещё не создал схему при первом старте)" \
       "— адреса клиента не правлю; при первом запуске realm импортируется из runtime, иначе добавьте вручную" \
       "в консоли Keycloak (Clients -> crm-bff): ${REDIRECTS[*]}"
fi

# --- применить окружение ---------------------------------------------------------------------------------
echo "set_host: пересоздаю сервисы с новым окружением"
dc up -d --wait --wait-timeout 300 --pull never
# Keycloak кэширует клиентов: правку БД он увидит только после рестарта.
dc restart keycloak >/dev/null
dc up -d --wait --wait-timeout 300 --pull never keycloak

echo "set_host: проверка (smoke)"
smoke_args=()
[[ "${MODE}" == internal ]] && smoke_args+=(--insecure)
if [[ "${MODE}" == off ]]; then
  bash "${SCRIPT_DIR}/smoke.sh" "http://localhost:${RTK_HTTP_PORT}" --timeout 240
else
  bash "${SCRIPT_DIR}/smoke.sh" "${RTK_BASE_URL}" ${smoke_args[@]+"${smoke_args[@]}"} --timeout 300
fi
echo "set_host: готово: ${RTK_BASE_URL}"
