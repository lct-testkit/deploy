#!/usr/bin/env bash
# Проверка офлайн-бандла: каждая запись scripts/bundle_manifest.txt существует, а каждый путь вида scripts/…, docs/…,
# compose/…, seed/…, images.yaml, упомянутый в RUNBOOK.md и README бандла, либо входит в бандл, либо явно помечен в манифесте
# (`!` — намеренно не входит, `~` — создаётся установщиком). Иначе RUNBOOK бандла отправляет оператора к файлу, которого у него нет.
#
#   bash scripts/check_bundle_refs.sh [--stage <каталог собранного бандла>]
#
# Без --stage сверяет репозиторий с манифестом (так гоняется в validate.yml), со --stage — ещё и содержимое собранного бандла
# (build_offline_bundle.sh вызывает так перед упаковкой). Только bash, grep, sed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
MANIFEST="${REPO_DIR}/scripts/bundle_manifest.txt"
[[ -f "${MANIFEST}" ]] || { echo "нет ${MANIFEST}" >&2; exit 1; }

bundled=(); skipped=(); generated=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [[ -n "${line}" ]] || continue
  case "${line}" in
    '!'*) skipped+=("${line#!}") ;;
    '~'*) generated+=("${line#\~}") ;;
    *) bundled+=("${line}") ;;
  esac
done < "${MANIFEST}"

fail=0
for p in "${bundled[@]}"; do
  [[ -e "${REPO_DIR}/${p}" ]] || { echo "манифест: нет ${p} в репозитории" >&2; fail=1; }
  [[ -z "${STAGE}" || -e "${STAGE}/${p}" ]] || { echo "бандл: нет ${p}" >&2; fail=1; }
done
for p in "${skipped[@]}"; do
  [[ -e "${REPO_DIR}/${p}" ]] || { echo "манифест: нет ${p} (помечен «не входит», но и в репозитории его нет)" >&2; fail=1; }
done

# covered <путь> — входит ли в бандл (сам файл или каталог выше), либо помечен в манифесте.
covered() {
  local ref="$1" p
  for p in "${bundled[@]}" "${skipped[@]}" "${generated[@]}"; do
    [[ "${ref}" == "${p}" || "${ref}" == "${p}"/* || "${p}" == "${ref}"/* ]] && return 0
  done
  return 1
}

docs=("${STAGE:-${REPO_DIR}}/RUNBOOK.md")
[[ -n "${STAGE}" && -f "${STAGE}/README.md" ]] && docs+=("${STAGE}/README.md")
[[ -f "${docs[0]}" ]] || { echo "нет ${docs[0]}" >&2; exit 1; }

# Ссылка — путь не внутри URL/другого пути (перед ним нет букв, /, ., :, -).
refs="$(LC_ALL=C grep -ohE '(^|[^A-Za-z0-9_/.:-])((scripts|docs|compose|seed|charts|mocks|site)/[A-Za-z0-9_./*-]*[A-Za-z0-9_]|images\.yaml)' "${docs[@]}" | sed -E 's/^[^a-z]+//' | sort -u || true)"
while IFS= read -r ref; do
  [[ -n "${ref}" ]] || continue
  [[ "${ref}" == *'*'* ]] && continue
  covered "${ref}" || { echo "RUNBOOK/README ссылается на ${ref}, а его нет в манифесте бандла (добавьте в scripts/bundle_manifest.txt: без «!» — положить в бандл, с «!» — сознательно не класть)" >&2; fail=1; }
done <<<"${refs}"

[[ ${fail} -eq 0 ]] && echo "бандл: ссылки RUNBOOK/README сходятся с манифестом ($(wc -l <<<"${refs}") путей)"
exit ${fail}
