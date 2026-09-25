#!/usr/bin/env bash
# Синхронизирует seed/ (скрипты моковых данных) с frontend/tools.
#
#   bash scripts/sync_seed.sh --frontend-dir ../frontend           # обновить seed/ из frontend
#   bash scripts/sync_seed.sh --frontend-dir ../frontend --check   # только сверить, код 1 при расхождении
#
# Источник истины — репозиторий frontend: сиды пишутся там, вместе с API-клиентом и демо-учётками.
# В deploy лежат копии, чтобы они ехали в офлайн-бандл и запускались в контейнере node без сети.
# Копии не правим руками: меняется только строка импорта хелпера (`../lib.mjs` -> `./lib.mjs`),
# остальной код совпадает с frontend построчно; `lib.mjs` — урезанная выжимка frontend/tools/lib.mjs
# (BASE, ACCOUNTS, токен, согласие) без playwright, которого в образе node нет, плюс преамбула
# scripts/seed_lib_preamble.mjs: подмена адреса для работы внутри сети compose (см. комментарий в ней).
#
#   frontend/tools/seed-demo.mjs                        -> seed/seed-demo.mjs
#   frontend/tools/scenarios/b-seed-catalogs.mjs        -> seed/catalogs.mjs
#   frontend/tools/scenarios/lead-seed-erasure.mjs      -> seed/erasure.mjs
#   frontend/tools/lib.mjs (выжимка)                    -> seed/lib.mjs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SEED_DIR="${REPO_DIR}/seed"
FRONTEND_DIR=""
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frontend-dir) FRONTEND_DIR="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${FRONTEND_DIR}" ]] || { echo "нужен --frontend-dir <путь к checkout frontend>" >&2; exit 2; }
TOOLS="${FRONTEND_DIR}/tools"
[[ -f "${TOOLS}/lib.mjs" ]] || { echo "нет ${TOOLS}/lib.mjs — это не checkout frontend?" >&2; exit 1; }

# Все копии в LF: в Windows-checkout frontend файлы могут быть с CRLF.
lf() { tr -d '\r'; }

# Урезанный lib.mjs: строки берём из frontend по маркерам. Если маркер пропал (файл
# перестроили), падаем громко, а не пишем пустой хелпер.
gen_lib() {
  local src="${TOOLS}/lib.mjs" base accounts session
  base="$(lf < "${src}" | grep -m1 '^export const BASE ')" || true
  accounts="$(lf < "${src}" | awk '/^export const ACCOUNTS = \{/ {f=1} f {print} f && /^};/ {exit}')"
  session="$(lf < "${src}" | awk '
    /^async function tokensFor\(/ {f=1}
    f {print}
    /^export async function ensureConsent\(/ {g=1}
    g && /^}$/ {exit}')"
  [[ -n "${base}" && -n "${accounts}" && -n "${session}" ]] \
    || { echo "не нашёл BASE/ACCOUNTS/tokensFor/ensureConsent в ${src}: структура lib.mjs изменилась, поправьте scripts/sync_seed.sh" >&2; return 1; }
  # Преамбула (подмена адреса для работы внутри сети compose) лежит отдельным файлом — её можно проверять node --check.
  lf < "${SCRIPT_DIR}/seed_lib_preamble.mjs"
  printf '%s\n%s\n\n%s\n' "${base}" "${accounts}" "${session}"
}

# Скрипт-сид с заменой единственной строки импорта.
gen_script() {
  lf < "$1" | sed "s|from '../lib.mjs'|from './lib.mjs'|"
}

# имя в seed/ : источник во frontend
FILES=(
  "seed-demo.mjs:${TOOLS}/seed-demo.mjs"
  "catalogs.mjs:${TOOLS}/scenarios/b-seed-catalogs.mjs"
  "erasure.mjs:${TOOLS}/scenarios/lead-seed-erasure.mjs"
)

for entry in "${FILES[@]}"; do
  [[ -f "${entry#*:}" ]] || { echo "нет источника ${entry#*:}" >&2; exit 1; }
done

mkdir -p "${SEED_DIR}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

gen_lib > "${TMP}/lib.mjs"
for entry in "${FILES[@]}"; do
  gen_script "${entry#*:}" > "${TMP}/${entry%%:*}"
done

status=0
for f in lib.mjs "${FILES[@]%%:*}"; do
  if [[ "${CHECK}" == 1 ]]; then
    if ! cmp -s "${TMP}/${f}" "${SEED_DIR}/${f}" 2>/dev/null; then
      echo "РАСХОЖДЕНИЕ: seed/${f} не совпадает с frontend (запустите scripts/sync_seed.sh --frontend-dir ${FRONTEND_DIR})" >&2
      status=1
    else
      echo "  ok    seed/${f}"
    fi
  else
    cp "${TMP}/${f}" "${SEED_DIR}/${f}"
    echo "  обновлён seed/${f}"
  fi
done
exit "${status}"
