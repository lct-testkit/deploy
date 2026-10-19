#!/usr/bin/env bash
# Сквозная проверка стека из образов images.yaml: поднять с нуля, прогнать smoke,
# (опционально) снять бэкап и проверить восстановление, убрать за собой.
#
#   bash scripts/e2e_stack.sh [--images-env <файл>] [--with-restore] [--keep] [--profile demo|prod]
#
# --profile prod: стек боевого профиля (APP_PROFILE=prod: обязательные ключи, без демо-пользователей, первый администратор
# с временным паролем); вместо моковых проверок — проверка prod: migrate завершился, демо-вход закрыт, пароль первого
# администратора временный. По умолчанию demo; в demo при возможности ещё проверяется профиль site (см. ниже).
#
# По умолчанию ссылки на образы берутся из images.yaml (режим digest) и требуют
# `docker login ghcr.io` — api/web в GHCR приватные. Секреты каждый раз новые
# (gen_env.sh), изолированный compose-проект rtk-e2e, порты 28080/28443/28333/25433.
#
# Несколько прогонов на одной машине (self-hosted раннеры делят один Docker-демон) не пересекаются,
# если задать E2E_PROJECT (имя compose-проекта) и E2E_PORT_OFFSET: число (все порты сдвигаются на него)
# или `auto` — скрипт сам берёт первый сдвиг 10…3990, при котором свободны все порты стенда и стенда
# проверки восстановления и который не совпадает с фиксированными портами сдвига 0 (notify, ручной
# запуск). Проверка восстановления получает тот же сдвиг и проект `<E2E_PROJECT>-restore`.
#
# При падении печатает хвосты логов сервисов — по ним видно причину без
# повторного прогона.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
PROJECT="${E2E_PROJECT:-rtk-e2e}"
PORT_OFFSET="${E2E_PORT_OFFSET:-0}"
# Базовые порты стенда и стенда восстановления (restore_test.sh) при сдвиге 0.
E2E_BASES=(28080 28443 28333 25433 25000)
RESTORE_BASES=(18080 18443 18333 15433 15000)
IMAGES_ENV_SRC=""
WITH_RESTORE=0
KEEP=0
PROFILE="demo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --images-env) IMAGES_ENV_SRC="$2"; shift 2 ;;
    --with-restore) WITH_RESTORE=1; shift ;;
    --keep) KEEP=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

case "${PROFILE}" in demo|prod) ;; *) echo "--profile: demo|prod" >&2; exit 2 ;; esac

PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

# Порт занят, если на localhost кто-то принимает соединение (docker-proxy публикует порты и на 0.0.0.0, и на 127.0.0.1).
port_busy() { timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$0"' "$1" 2>/dev/null; }

# Первый сдвиг 10…3990 (начиная со случайного места — параллельные прогоны не выбирают одно и то же), при котором
# свободны все порты обоих стендов и ни один из них не совпадает с фиксированными портами сдвига 0.
pick_offset() {
  local start=$(( (RANDOM * 32768 + RANDOM) % 399 )) i o b l p bad
  for (( i = 0; i < 399; i++ )); do
    o=$(( ((start + i) % 399 + 1) * 10 )); bad=0
    for b in "${E2E_BASES[@]}" "${RESTORE_BASES[@]}"; do
      p=$(( b + o ))
      for l in "${E2E_BASES[@]}" "${RESTORE_BASES[@]}"; do [[ ${p} -eq ${l} ]] && bad=1; done
      port_busy "${p}" && bad=1
    done
    if [[ ${bad} -eq 0 ]]; then echo "${o}"; return 0; fi
  done
  return 1
}

if [[ "${PORT_OFFSET}" == auto ]]; then
  PORT_OFFSET="$(pick_offset)" || { echo "не нашёл свободный сдвиг портов (все 399 заняты)" >&2; exit 1; }
fi
# Без ведущих нулей (иначе bash прочтёт 010 как восьмеричное) и с запасом до 65535.
[[ "${PORT_OFFSET}" =~ ^(0|[1-9][0-9]{0,3})$ ]] || { echo "E2E_PORT_OFFSET: число 0…9999 или auto, а не '${PORT_OFFSET}'" >&2; exit 2; }
echo "[e2e] проект ${PROJECT}, сдвиг портов ${PORT_OFFSET}"

# `pwd -W` — путь в виде C:/… для нативного docker.exe при запуске из Git Bash на Windows; на Linux не нужен.
WORK="$(cd "$(mktemp -d)" && { pwd -W 2>/dev/null || pwd; })"
export HTTP_PORT=$((28080 + PORT_OFFSET)) HTTPS_PORT=$((28443 + PORT_OFFSET)) S3_PROXY_PORT=$((28333 + PORT_OFFSET))
export POSTGRES_PORT=$((25433 + PORT_OFFSET)) REGISTRY_PORT=$((25000 + PORT_OFFSET))

dc() { docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${WORK}/.env" --env-file "${WORK}/.env.images" "$@"; }

# Снести проект по меткам compose, без интерполяции файла (нужна, когда рабочий каталог с .env уже удалён
# или прогон убили посреди restore_test.sh).
sweep_project() {
  local f="label=com.docker.compose.project=$1"
  docker ps -aq --filter "${f}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume ls -q --filter "${f}" | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker network ls -q --filter "${f}" | xargs -r docker network rm >/dev/null 2>&1 || true
}

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
    sweep_project "${PROJECT}-restore"
    rm -rf "${WORK}"
  else
    echo "стенд оставлен: проект ${PROJECT}, каталог ${WORK}"
  fi
  exit ${rc}
}
trap cleanup EXIT
# Отмена job'а и таймаут приходят сигналом: без этого EXIT-ловушка не сработала бы и стенд остался бы на общем демоне.
trap 'exit 143' TERM
trap 'exit 130' INT

echo "[e2e] секреты и конфиги"
bash "${SCRIPT_DIR}/gen_env.sh" --dir "${REPO_DIR}/compose" --state-dir "${WORK}" --profile "${PROFILE}" > "${WORK}/gen_env.out"

if [[ -n "${IMAGES_ENV_SRC}" ]]; then
  cp "${IMAGES_ENV_SRC}" "${WORK}/.env.images"
else
  "$PY" "${SCRIPT_DIR}/render_env_images.py" "${REPO_DIR}/images.yaml" > "${WORK}/.env.images"
fi

echo "[e2e] docker compose up (образы: $(grep -c '_IMAGE=' "${WORK}/.env.images"))"
dc up -d --wait --wait-timeout 420

echo "[e2e] smoke"
bash "${SCRIPT_DIR}/smoke.sh" "http://localhost:${HTTP_PORT}" --timeout 180 --env-file "${WORK}/.env"

env_val() { grep -E "^$1=" "${WORK}/.env" | tail -1 | cut -d= -f2- || true; }
BASE="http://localhost:${HTTP_PORT}"

if [[ "${PROFILE}" == prod ]]; then
  echo "[e2e] prod: migrate завершился успешно, демо-пользователей нет, первый администратор с временным паролем"
  mig="$(dc ps -a --format '{{.ExitCode}}' migrate | head -1)"
  [[ "${mig}" == 0 ]] || { echo "ОШИБКА: migrate завершился с кодом ${mig:-?}" >&2; exit 1; }
  # Пользователи realm crm через консоль Keycloak (admin-cli, realm master) — тем же путём, каким пользуется оператор.
  kc_token="$(curl -fsS -d client_id=admin-cli -d grant_type=password -d username="$(env_val KEYCLOAK_ADMIN)"     --data-urlencode password="$(env_val KEYCLOAK_ADMIN_PASSWORD)" "${BASE}/auth/realms/master/protocol/openid-connect/token"     | sed -n 's/.*"access_token":"\([^"]*\)".*//p')"
  [[ -n "${kc_token}" ]] || { echo "ОШИБКА: не получил токен администратора Keycloak" >&2; exit 1; }
  users="$(curl -fsS -H "Authorization: Bearer ${kc_token}" "${BASE}/auth/admin/realms/crm/users?max=100")"
  for demo in admin.crm admin.volkov head.petrov kam.ivanov auditor.smirnov; do
    ! grep -q "\"username\":\"${demo}\"" <<<"${users}" || { echo "ОШИБКА: в prod есть демо-пользователь ${demo}" >&2; exit 1; }
  done
  grep -q '"username":"admin"' <<<"${users}" || { echo "ОШИБКА: нет первого администратора admin" >&2; exit 1; }
  grep -q 'UPDATE_PASSWORD' <<<"${users}" || { echo "ОШИБКА: у первого администратора нет требования сменить пароль" >&2; exit 1; }
  # Форма браузерного входа Keycloak (клиент crm-bff: code + PKCE, прямой вход по паролю выключен). Ссылку формы Keycloak
  # строит на BASE_URL из .env, а стенд слушает на сдвинутом порту — подменяем адрес. 200 на отправку формы = «не вошёл»
  # (снова страница входа), 302 = принят (дальше редирект).
  pub="$(env_val BASE_URL)"
  kc_submit() { # <логин> <пароль> -> печатает «код Location»
    local jar="${WORK}/kc.cookies" page act
    rm -f "${jar}"
    page="$(curl -fsS -c "${jar}" "${BASE}/auth/realms/crm/protocol/openid-connect/auth?client_id=crm-bff&response_type=code&redirect_uri=${pub}/&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256")"
    act="$(sed -n 's/.*action="\([^"]*\)".*/\1/p' <<<"${page}" | head -1 | sed 's/&amp;/\&/g')"
    [[ -n "${act}" ]] || { echo "ОШИБКА: форма входа Keycloak не разобрана" >&2; return 1; }
    act="${BASE}${act#"${pub}"}"
    curl -sS -b "${jar}" -D "${WORK}/kc.headers" -o /dev/null -w '%{http_code}' -d "username=$1" --data-urlencode "password=$2" "${act}"
    echo " $(grep -i '^location:' "${WORK}/kc.headers" | tr -d '\r' | head -1)"
  }
  demo_login="$(kc_submit admin.crm 'Admin12345678!')"
  [[ "${demo_login%% *}" == 200 ]] || { echo "ОШИБКА: вход demo admin.crm/Admin12345678! в prod не отклонён (${demo_login})" >&2; exit 1; }
  first_login="$(kc_submit admin "$(env_val CRM_ADMIN_INITIAL_PASSWORD)")"
  [[ "${first_login%% *}" == 302 && "${first_login}" == *required-action* ]] \
    || { echo "ОШИБКА: первый администратор должен получить требование сменить пароль (${first_login})" >&2; exit 1; }
  echo "  ok    prod: демо-вход отклонён, первый администратор обязан сменить пароль"
fi

# Выключенные профили (monitoring, site) для посетителя — 404, а не 502 от Caddy; внутренности Mailpit наружу не выдаются.
for path in /grafana/ /site/; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}${path}" || true)"
  [[ "${code}" == 404 ]] || { echo "ОШИБКА: ${path} при выключенном профиле отвечает ${code}, ожидали 404" >&2; exit 1; }
done
if grep -qE '^COMPOSE_PROFILES=.*mail' "${WORK}/.env"; then
  for path in /mail/api/v1/info /mail/api/v1/webui; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}${path}" || true)"
    [[ "${code}" == 404 ]] || { echo "ОШИБКА: ${path} отвечает ${code}, ожидали 404" >&2; exit 1; }
  done
fi
echo "  ok    /grafana/, /site/ при выключенных профилях — 404; /mail/api/v1/info и /webui закрыты"

# Профиль site: образ сайта собирается только под amd64 (все узлы стенда x86_64), на aarch64-раннере его не запустить.
# Проверяем: контейнер healthy (healthcheck задан в compose и в образе) и /site/ отвечает 200. Раньше в registry уехал образ
# стадии test (CMD phpunit): контейнер «жил», а сайта не было, и `up --wait` этого не замечал.
if [[ "${PROFILE}" == demo && ( "$(uname -m)" == x86_64 || "${E2E_SITE:-0}" == 1 ) ]]; then
  echo "[e2e] профиль site"
  dc --profile site up -d --wait --wait-timeout 300 site
  health="$(docker inspect --format '{{.State.Health.Status}}' "$(dc --profile site ps -q site)" 2>/dev/null || true)"
  [[ "${health}" == healthy ]] || { echo "ОШИБКА: контейнер site не healthy (${health:-нет healthcheck})" >&2; exit 1; }
  site_code=""
  for _ in $(seq 1 20); do
    site_code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/site/" || true)"
    [[ "${site_code}" == 200 ]] && break
    sleep 3
  done
  [[ "${site_code}" == 200 ]] || { echo "ОШИБКА: ${BASE}/site/ отвечает ${site_code:-нет ответа}, ожидали 200" >&2; exit 1; }
  echo "  ok    site healthy, /site/ 200"
elif [[ "${PROFILE}" == demo ]]; then
  echo "[e2e] профиль site пропущен: хост $(uname -m), образ сайта только amd64 (E2E_SITE=1 — принудительно)"
fi

if [[ "${WITH_RESTORE}" == 1 ]]; then
  echo "[e2e] бэкап"
  BACKUP="$(bash "${SCRIPT_DIR}/backup.sh" --env-file "${WORK}/.env" --images-env "${WORK}/.env.images" \
              --project "${PROJECT}" --compose "${COMPOSE_FILE}" --out "${WORK}/backups" | tail -1)"
  echo "[e2e] проверка восстановления"
  RESTORE_TEST_PROJECT="${PROJECT}-restore" RESTORE_TEST_PORT_OFFSET="${PORT_OFFSET}" \
    bash "${SCRIPT_DIR}/restore_test.sh" --backup "${BACKUP}" --env-file "${WORK}/.env" \
         --images-env "${WORK}/.env.images" --compose "${COMPOSE_FILE}"
fi

echo "[e2e] ВСЁ ЗЕЛЁНОЕ"
