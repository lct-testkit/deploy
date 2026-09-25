#!/usr/bin/env bash
# Заливает образы из офлайн-бандла во внутренний registry контура.
#
#   bash registry_load.sh <host:port> [images.tsv]
#
# Предполагает, что образы уже загружены в локальный docker (`docker load`, это
# делает install.sh) и что registry доступен по <host:port> (профиль compose
# `registry`, по умолчанию localhost:5000). После заливки на любой машине
# контура образы берутся из registry:
#
#   python3 scripts/render_env_images.py --mode registry --registry <host:port> > .env.images
#
# TSV (имя<TAB>источник<TAB>bundle-ссылка<TAB>registry-ссылка) лежит в бандле как
# images.tsv; ссылка registry там записана для localhost:5000 и пересчитывается
# под переданный <host:port>.
set -euo pipefail

REGISTRY="${1:?использование: registry_load.sh <host:port> [images.tsv]}"
TSV="${2:-$(dirname "${BASH_SOURCE[0]}")/../images.tsv}"
[[ -f "${TSV}" ]] || { echo "нет ${TSV}" >&2; exit 1; }

while IFS=$'\t' read -r name _source bundle_ref _reg_ref; do
  [[ -z "${name}" ]] && continue
  tag="${bundle_ref##*:}"
  target="${REGISTRY}/${name}:${tag}"
  echo "[registry] ${bundle_ref} -> ${target}"
  docker tag "${bundle_ref}" "${target}"
  docker push "${target}"
done < "${TSV}"

echo "[registry] готово: $(wc -l < "${TSV}") образов в ${REGISTRY}"
