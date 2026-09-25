#!/usr/bin/env bash
# Проверяет, что образ реально существует в GHCR и что тег указывает именно
# на заявленный digest. Вызывается до записи tag/digest в images.yaml — иначе
# опечатка в dispatch-payload (или чужой dispatch) отравляет манифест, и это
# всплывает только на раскатке.
#
#   scripts/verify_image.sh <image> <tag> <digest> [registry-prefix]
#
# Требует предварительного `docker login ghcr.io` токеном с read:packages.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "использование: verify_image.sh <image> <tag> <digest> [registry-prefix]" >&2
  exit 2
fi

image="$1"
tag="$2"
digest="$3"
prefix="${4:-ghcr.io/lct-testkit}"

if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::digest=${digest}: ожидается sha256:<64 hex>" >&2
  exit 1
fi

ref="${prefix}/${image}:${tag}"
actual="$(docker buildx imagetools inspect "$ref" --format '{{ .Manifest.Digest }}')"

if [ "$actual" != "$digest" ]; then
  echo "::error::${ref} указывает на ${actual}, а заявлен ${digest}" >&2
  exit 1
fi

echo "OK: ${ref} -> ${digest}"
