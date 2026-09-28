#!/usr/bin/env bash
# Проверяет, что образ реально существует в GHCR и что тег указывает именно
# на заявленный digest. Вызывается до записи tag/digest в images.yaml — иначе
# опечатка в dispatch-payload (или чужой dispatch) отравляет манифест, и это
# всплывает только на раскатке.
#
#   scripts/verify_image.sh <image> <tag> <digest> [registry-prefix]
#
# Требует предварительного `docker login ghcr.io` токеном с read:packages.
#
# Платформы: манифест-индекс обязан содержать все архитектуры из REQUIRE_ARCHES
# (через пробел, по умолчанию только amd64 — прод и офлайн-бандл ставятся на x86).
# Образ, собранный на aarch64-раннере без --platform, был бы arm64-only и не
# запустился бы на прод-сервере, хотя digest и тег «правильные».
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

# Сырой индекс без пробелов/переводов строк: порядок ключей в platform{} не гарантирован
# спецификацией, поэтому ищем не пару "architecture"+"os", а каждое поле отдельно.
raw="$(docker buildx imagetools inspect "$ref" --raw | tr -d ' \n\r\t')"
for arch in ${REQUIRE_ARCHES:-amd64}; do
  if ! grep -q "\"architecture\":\"${arch}\"" <<<"$raw"; then
    echo "::error::${ref}: в манифесте нет linux/${arch} (требуется: ${REQUIRE_ARCHES:-amd64})" >&2
    exit 1
  fi
done
if ! grep -q '"os":"linux"' <<<"$raw"; then
  echo "::error::${ref}: в манифесте нет ни одной linux-платформы" >&2
  exit 1
fi

echo "OK: ${ref} -> ${digest} (платформы: ${REQUIRE_ARCHES:-amd64})"
