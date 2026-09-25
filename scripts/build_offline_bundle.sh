#!/usr/bin/env bash
# Собирает офлайн-поставку для закрытого контура: один архив с образами
# (docker save), compose-профилем, скриптами установки и контрольными суммами.
#
#   scripts/build_offline_bundle.sh [версия] [--images images.yaml] [--out DIR]
#                                   [--allow-missing] [--split-mb 1900]
#
# Что внутри (rtk-crm-offline-<версия>/):
#   images.tar.gz        все образы под именами rtk-offline/<имя>:<тег>
#   images.tsv           имя / источник / bundle-ссылка / registry-ссылка
#   env/images.bundle.env  готовый .env.images (образы из docker load)
#   compose/             docker-compose.yml, .env.example, Caddyfile, конфиги
#   scripts/             gen_env.sh, registry_load.sh, smoke.sh
#   install.sh           установщик (проверка SHA256SUMS → docker load → up)
#   SHA256SUMS           контрольные суммы всех файлов бандла
#
# Образы тянутся строго по images.yaml (tag@digest), а не из локального кэша,
# поэтому сборка воспроизводима на любой машине с доступом к GHCR. После pull
# образ перетегируется в rtk-offline/…: у образов, загруженных `docker load`,
# нет RepoDigests, и ссылка вида `repo@sha256:…` заставила бы docker идти в
# сеть. Целостность обеспечивают SHA256SUMS и подпись (release.yml).
#
# Архив больше --split-mb режется на части (лимит вложения GitHub Release 2 ГиБ);
# собрать обратно: cat rtk-crm-offline-*.tar.gz.part-* > rtk-crm-offline.tar.gz
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# На целевых серверах (Debian/Ubuntu) есть `python3`; на Windows/Git Bash —
# обычно `python`. Берём что есть.
PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

IMAGES_FILE="images.yaml"
OUT_BASE="${REPO_DIR}"
ALLOW_MISSING=0
SPLIT_MB=1900
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --images) IMAGES_FILE="$2"; shift 2 ;;
    --out) OUT_BASE="$2"; shift 2 ;;
    --allow-missing) ALLOW_MISSING=1; shift ;;
    --split-mb) SPLIT_MB="$2"; shift 2 ;;
    -*) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    *) VERSION="$1"; shift ;;
  esac
done
VERSION="${VERSION:-sha-$(git rev-parse --short=7 HEAD)}"
mkdir -p "${OUT_BASE}"
OUT_BASE="$(cd "${OUT_BASE}" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
NAME="rtk-crm-offline-${VERSION}"
STAGE="${WORK}/${NAME}"
mkdir -p "${STAGE}"/{compose,scripts,env}

log() { echo "[bundle] $*"; }
RENDER_ARGS=("${IMAGES_FILE}")
[[ "${ALLOW_MISSING}" == 1 ]] && RENDER_ARGS+=(--allow-missing)
render() { "$PY" scripts/render_env_images.py "${RENDER_ARGS[@]}" "$@"; }

log "версия ${VERSION}, каталог сборки ${STAGE}"

# --- 1. Образы: pull по digest → перетегирование → save -----------------------
render --list --registry "localhost:5000" | tr -d '\r' > "${STAGE}/images.tsv"
[[ -s "${STAGE}/images.tsv" ]] || { echo "images.yaml: нет образов с tag/digest" >&2; exit 1; }

BUNDLE_REFS=()
while IFS=$'\t' read -r name source bundle_ref _reg; do
  log "docker pull ${source}"
  docker pull --quiet "${source}" >/dev/null
  docker tag "${source}" "${bundle_ref}"
  BUNDLE_REFS+=("${bundle_ref}")
  echo "  ${name}: ${bundle_ref}"
done < "${STAGE}/images.tsv"

log "docker save (${#BUNDLE_REFS[@]} образов) → images.tar.gz"
docker save "${BUNDLE_REFS[@]}" | gzip -6 > "${STAGE}/images.tar.gz"

# --- 2. Готовый .env.images для офлайн-режима -----------------------------------
render --mode bundle > "${STAGE}/env/images.bundle.env"

# --- 3. compose и скрипты: отсутствие любого файла — ошибка --------------------
for f in compose/docker-compose.yml compose/.env.example compose/Caddyfile \
         compose/keycloak/realm-crm.json compose/seaweedfs/s3.json compose/postgres/init-keycloak-db.sh \
         scripts/gen_env.sh scripts/registry_load.sh scripts/smoke.sh scripts/bundle_install.sh; do
  [[ -f "${f}" ]] || { echo "нет файла ${f} — бандл был бы неполным" >&2; exit 1; }
done
cp compose/docker-compose.yml compose/.env.example compose/Caddyfile "${STAGE}/compose/"
cp -r compose/keycloak compose/seaweedfs compose/postgres "${STAGE}/compose/"
cp scripts/gen_env.sh scripts/registry_load.sh scripts/smoke.sh "${STAGE}/scripts/"
cp scripts/bundle_install.sh "${STAGE}/install.sh"
[[ -f RUNBOOK.md ]] && cp RUNBOOK.md "${STAGE}/RUNBOOK.md"

cat > "${STAGE}/README.md" <<EOF
# RTK School CRM — офлайн-поставка ${VERSION}

Установка на машине без доступа в интернет (нужны только Docker и плагин
\`docker compose\`, установленные заранее):

\`\`\`bash
bash install.sh                     # демо-режим, секреты генерируются
bash install.sh --profile prod --host crm.example.local
bash install.sh --registry          # дополнительно поднять внутренний registry (localhost:5000)
\`\`\`

Установщик сам проверяет SHA256SUMS до загрузки образов и падает при
любом расхождении. Подпись бандла (cosign) и описание перехода на внутренний
registry — в RUNBOOK.md.
EOF

# --- 4. Контрольные суммы всех файлов бандла --------------------------------
( cd "${STAGE}" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
log "SHA256SUMS: $(wc -l < "${STAGE}/SHA256SUMS") файлов"

# --- 5. Итоговый архив (+ нарезка при необходимости) --------------------------
FINAL="${OUT_BASE}/${NAME}.tar.gz"
tar -C "${WORK}" -czf "${FINAL}" "${NAME}"
size_mb=$(( $(stat -c %s "${FINAL}") / 1024 / 1024 ))
log "архив: ${FINAL} (${size_mb} МиБ)"

if (( size_mb > SPLIT_MB )); then
  log "больше ${SPLIT_MB} МиБ — нарезаю на части"
  split -b "${SPLIT_MB}M" -d "${FINAL}" "${FINAL}.part-"
  rm -f "${FINAL}"
  ( cd "${OUT_BASE}" && sha256sum "${NAME}.tar.gz.part-"* > "${NAME}.parts.sha256" )
  log "части: $(ls "${OUT_BASE}/${NAME}.tar.gz.part-"* | wc -l), суммы: ${NAME}.parts.sha256"
else
  ( cd "${OUT_BASE}" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )
fi
log "готово"
