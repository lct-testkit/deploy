#!/usr/bin/env bash
# Заливает моковые данные в поднятый ДЕМО-стенд: справочники (направления, причины отказа, праздники, пользовательские
# поля), организации, контакты, сделки, задачи, реестр ЕГРЮЛ, SLA, сценарии «Удаление ПДн». Скрипты лежат в seed/,
# исполняются одноразовым контейнером seed-demo (профиль compose demo-data) внутри сети стека.
#
#   bash scripts/seed_demo.sh [--env-file F] [--images-env F] [--compose FILE] [--project NAME]
#                             [--only catalogs,demo,erasure]
#
# По умолчанию — стенд из бандла/чекаута рядом со скриптом: compose/.env, compose/.env.images, проект из compose.
# Для окружений deploy.sh: --env-file /srv/rtk-demo/.env --images-env /srv/rtk-demo/.env.images --project rtk-demo.
# Идемпотентно: повторный запуск ничего не дублирует. Только APP_PROFILE=demo: в prod Bearer-вход ограничен ролью
# INTEGRATION, а /config.json не отдаёт секрет клиента — сиды там не работают, а мок-данные в боевой системе не нужны.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_DIR}/compose/docker-compose.yml"
ENV_FILE="${REPO_DIR}/compose/.env"
IMAGES_ENV="${REPO_DIR}/compose/.env.images"
PROJECT=""
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --images-env) IMAGES_ENV="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

die() { echo "seed: $*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || die "нет ${ENV_FILE} — стенд не установлен"
[[ -f "${IMAGES_ENV}" ]] || die "нет ${IMAGES_ENV} — стенд не установлен"
[[ -f "${REPO_DIR}/seed/run.sh" ]] || die "нет ${REPO_DIR}/seed/run.sh — неполный бандл/чекаут"

profile="$(grep -E '^APP_PROFILE=' "${ENV_FILE}" | tail -1 | cut -d= -f2-)"
if [[ "${profile:-demo}" != "demo" ]]; then
  die "профиль '${profile}': моковые данные заливаются только в demo (в prod они не нужны и не заработают)"
fi

proj_args=()
[[ -n "${PROJECT}" ]] && proj_args=(-p "${PROJECT}")
dc() {
  docker compose ${proj_args[@]+"${proj_args[@]}"} -f "${COMPOSE_FILE}" \
    --env-file "${ENV_FILE}" --env-file "${IMAGES_ENV}" "$@"
}

if [[ -z "$(dc ps --status running --quiet api 2>/dev/null || true)" ]]; then
  die "контейнер api не запущен — сначала поднимите стек (docker compose ... up -d --wait)"
fi

run_args=(--rm --no-deps -T)
[[ -n "${ONLY}" ]] && run_args+=(-e "SEED_ONLY=${ONLY}")

echo "seed: заливаю моковые данные${ONLY:+ (этапы: ${ONLY})}"

seed_fail() {
  echo "seed: ОШИБКА (код $1). Повтор безопасен: bash scripts/seed_demo.sh" >&2
  exit "$1"
}

# Полный прогон идёт в три приёма: справочники и сделки -> витрина (история во времени, SLA, прогресс обучения) ->
# готовые отчёты и сценарии удаления ПДн. С `--only` выполняется ровно то, что попросили.
if [[ -n "${ONLY}" ]]; then
  dc --profile demo-data run "${run_args[@]}" seed-demo || seed_fail $?
else
  dc --profile demo-data run "${run_args[@]}" -e SEED_ONLY=catalogs,demo seed-demo || seed_fail $?
  # Сиды ходят в API, а он создаёт всё «сейчас»: у всех сделок один момент перехода, среднее время в статусе 0, SLA либо
  # у всех в норме, либо у всех просрочен. Витрина растягивает историю (запуск под суперпользователем БД: история переходов
  # неизменяема для роли приложения) и раскладывает 4 просрочки SLA. Сбой витрины (например, старый образ api без модуля)
  # установку не ломает: демо остаётся рабочим, только с нулевыми сроками.
  echo "seed: витрина демо-данных (история сделок во времени, SLA, прогресс обучения)"
  if ! dc run --rm --no-deps -T --entrypoint python migrate -m app.mocks.demo_showcase; then
    echo "seed: ! витрина не применена (образ api без app.mocks.demo_showcase?) — отчёты покажут нулевые сроки" >&2
  fi
  dc --profile demo-data run "${run_args[@]}" -e SEED_ONLY=reports,erasure seed-demo || seed_fail $?
fi
echo "seed: моковые данные залиты"
