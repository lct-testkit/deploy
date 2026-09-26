#!/bin/sh
# Запускается в контейнере seed-demo (node:alpine, см. compose/docker-compose.yml): ждёт готовности API,
# затем по порядку три сида. Каждый идемпотентен, повторный запуск ничего не дублирует.
#
#   SEED_ONLY=catalogs,demo,erasure   какие этапы выполнять (по умолчанию все три)
#
# Порядок важен: справочники (направления, причины отказа, праздники, пользовательские поля) -> организации,
# сделки, задачи, ЕГРЮЛ, SLA -> сценарии удаления ПДн. Мягкие предупреждения скриптов («! переход не выполнен»,
# например передача в LMS без LMS_BASE_URL) код возврата не меняют; жёсткая ошибка любого этапа даёт код != 0.
set -eu

APP_URL="${APP_URL:-http://caddy:8080}"
export APP_URL
ONLY="${SEED_ONLY:-catalogs,demo,erasure}"

for s in $(echo "${ONLY}" | tr ',' ' '); do
  case "${s}" in
    catalogs|demo|erasure) ;;
    *) echo "seed: неизвестный этап '${s}' (доступно: catalogs, demo, erasure)" >&2; exit 2 ;;
  esac
done

echo "seed: жду API (${APP_URL}/health/ready)"
attempt=0
until wget -q -T 5 -O /dev/null "${APP_URL}/health/ready"; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 60 ]; then
    echo "seed: API не стал готов за 120 с" >&2
    exit 1
  fi
  sleep 2
done

step() { # step <этап> <файл> <описание>
  case ",${ONLY}," in
    *",$1,"*) ;;
    *) echo "seed: этап $1 пропущен (SEED_ONLY)"; return 0 ;;
  esac
  echo "== seed: $1 — $3 =="
  node "/seed/$2"
}

step catalogs catalogs.mjs "справочники: направления, причины отказа, праздники 2026, пользовательские поля"
step demo seed-demo.mjs "организации, контакты, сделки, задачи, реестр ЕГРЮЛ, SLA-правила"
step erasure erasure.mjs "сценарии «Удаление ПДн» и «Согласования»"
echo "seed: готово"
