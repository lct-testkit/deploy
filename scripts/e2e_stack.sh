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
  RESTORE_TEST_PROJECT="${PROJECT}-restore" RESTORE_TEST_PORT_OFFSET="${PORT_OFFSET}" \
    bash "${SCRIPT_DIR}/restore_test.sh" --backup "${BACKUP}" --env-file "${WORK}/.env" \
         --images-env "${WORK}/.env.images" --compose "${COMPOSE_FILE}"
fi

echo "[e2e] ВСЁ ЗЕЛЁНОЕ"
