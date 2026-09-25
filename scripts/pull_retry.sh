#!/usr/bin/env bash
# docker pull с повторами: Docker Hub / GHCR иногда отвечают 502/503/429, и один такой сбой
# не должен ронять CI (job'ы actionlint, hadolint, shellcheck и т.п. запускают инструменты образами).
#
#   scripts/pull_retry.sh <образ> [попыток=4]
set -euo pipefail

image="${1:?использование: pull_retry.sh <образ> [попыток]}"
attempts="${2:-4}"

for attempt in $(seq 1 "${attempts}"); do
  if docker pull --quiet "${image}" >/dev/null; then
    echo "образ ${image} получен (попытка ${attempt})"
    exit 0
  fi
  echo "::warning::docker pull ${image} не удался (попытка ${attempt}/${attempts})" >&2
  sleep $((attempt * 10))
done

echo "::error::не удалось скачать ${image} за ${attempts} попыток" >&2
exit 1
