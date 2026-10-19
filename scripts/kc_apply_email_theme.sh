#!/usr/bin/env bash
# Подключает русскую email-тему rtk-crm к realm `crm` УЖЕ УСТАНОВЛЕННОГО стенда.
#
#   bash scripts/kc_apply_email_theme.sh [--env-file compose/.env] [--images-env compose/.env.images]
#                                        [--compose FILE] [--project NAME] [--container NAME] [--force]
#
#   --container  имя контейнера Keycloak (docker exec напрямую, без docker compose): для стендов, поднятых не из
#                compose/docker-compose.yml, и узлов HA
#   --force      применить, даже если у realm уже выбрана какая-то email-тема
#
# Зачем отдельный скрипт. Realm Keycloak импортируется ОДИН РАЗ, при создании БД Keycloak: новые настройки из
# realm-crm.json (emailTheme, supportedLocales) у стенда, установленного раньше, сами не применяются. Файлы темы
# приезжают вместе с новой версией compose (том ./keycloak/themes/rtk-crm), а выбрать её в realm надо отдельно.
#
# Что делает (через kcadm.sh внутри контейнера keycloak, учётка администратора master realm берётся из его же
# окружения KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD, наружу пароль не попадает):
#   - emailTheme=rtk-crm;
#   - supportedLocales=["ru"], defaultLocale=ru, internationalizationEnabled=true: письмо «забыли пароль» всегда на
#     русском, а не по языку браузера (Keycloak берёт язык письма из locale пользователя и Accept-Language, но только
#     из числа supportedLocales);
#   - если SMTP уже настроен, а имя отправителя пустое: fromDisplayName="РТК Школа CRM".
# Идемпотентен: если у realm уже выбрана какая-то email-тема (в том числе чужая, заданная администратором), ничего
# не меняет и говорит об этом; --force переопределяет. Чтобы Keycloak увидел новые файлы темы, контейнер должен
# быть запущен после появления тома (up -d пересоздаёт его сам, когда compose-файл изменился).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_DIR}/compose/.env"
IMAGES_ENV="${REPO_DIR}/compose/.env.images"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
PROJECT=""
CONTAINER=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --images-env) IMAGES_ENV="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

die() { echo "kc_apply_email_theme: $*" >&2; exit 1; }

# Выполнить bash-скрипт внутри контейнера keycloak (stdin не используется).
kc_exec() {
  if [[ -n "${CONTAINER}" ]]; then
    docker exec "${CONTAINER}" bash -c "$1"
  else
    local proj_args=()
    [[ -n "${PROJECT}" ]] && proj_args=(-p "${PROJECT}")
    docker compose ${proj_args[@]+"${proj_args[@]}"} -f "${COMPOSE_FILE}" \
      --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV}" exec -T keycloak bash -c "$1"
  fi
}

KCADM='/opt/keycloak/bin/kcadm.sh'
CFG='--config /tmp/kcadm-rtk.config'
LOGIN="${KCADM} config credentials ${CFG} --server http://localhost:8080/auth --realm master --user \"\$KEYCLOAK_ADMIN\" --password \"\$KEYCLOAK_ADMIN_PASSWORD\" >/dev/null"

kc_exec "${LOGIN}" 2>/dev/null \
  || die "не удалось войти в Keycloak под администратором master realm (пароль мог быть сменён в консоли; контейнер не запущен?). Задайте тему вручную: консоль Keycloak -> Realm settings -> Themes -> Email theme = rtk-crm, затем Localization: оставить только русский"

state="$(kc_exec "${KCADM} get realms/crm ${CFG}" 2>/dev/null)" || die "realm crm не найден"
smtp="$(printf '%s' "${state}" | sed -n '/"smtpServer"/,/}/p')"

# Тема уже выбрана: своё не затираем.
current="$(printf '%s' "${state}" | sed -n 's/.*"emailTheme"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [[ "${current}" == "rtk-crm" ]]; then
  echo "kc_apply_email_theme: email-тема rtk-crm уже выбрана — ничего не меняю"
  exit 0
fi
if [[ -n "${current}" && "${FORCE}" != 1 ]]; then
  echo "kc_apply_email_theme: у realm crm выбрана email-тема '${current}' (задана вручную) — не меняю; --force переопределит"
  exit 0
fi

kc_exec "${KCADM} update realms/crm ${CFG} -s emailTheme=rtk-crm -s internationalizationEnabled=true -s 'supportedLocales=[\"ru\"]' -s defaultLocale=ru" \
  || die "не удалось обновить realm crm"
echo "kc_apply_email_theme: realm crm: emailTheme=rtk-crm, язык писем ru"

# Имя отправителя: только если SMTP настроен (иначе Keycloak не шлёт писем) и имя не задано.
if printf '%s' "${smtp}" | grep -q '"host"' && ! printf '%s' "${smtp}" | grep -q '"fromDisplayName"[[:space:]]*:[[:space:]]*"[^"]'; then
  kc_exec "${KCADM} update realms/crm ${CFG} -s 'smtpServer.fromDisplayName=РТК Школа CRM'" \
    && echo "kc_apply_email_theme: имя отправителя: РТК Школа CRM"
fi
kc_exec "rm -f /tmp/kcadm-rtk.config" || true
