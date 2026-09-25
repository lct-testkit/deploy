#!/usr/bin/env bash
# Установка RTK School CRM из офлайн-бандла на машине БЕЗ доступа в интернет.
# Копируется в бандл как install.sh. Нужны только Docker и плагин docker compose.
#
#   bash install.sh [--profile demo|prod] [--host <имя/IP>] [--registry] [--no-start]
#
#   --profile   demo (по умолчанию) или prod (APP_PROFILE и APP_MODE=prod)
#   --host      публичное имя/IP сервера (BASE_URL, Keycloak, S3, TLS)
#   --registry  поднять внутренний registry (localhost:5000) и залить в него образы
#   --no-start  только проверить, загрузить образы и создать .env, стек не запускать
#
# Порядок: SHA256SUMS → (подпись, если есть cosign) → docker load → секреты →
# compose up --wait → smoke. На любом расхождении контрольных сумм установка
# прерывается ДО загрузки образов.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE=demo
HOST=""
WITH_REGISTRY=0
START=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --registry) WITH_REGISTRY=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null || { echo "docker не найден" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "плагин 'docker compose' не найден" >&2; exit 1; }

echo "== 1/5 проверка контрольных сумм =="
sha256sum --quiet -c SHA256SUMS || { echo "ОШИБКА: контрольные суммы не сошлись — бандл повреждён или изменён" >&2; exit 1; }
echo "   SHA256SUMS: ок ($(wc -l < SHA256SUMS) файлов)"

if [[ -f SHA256SUMS.sigstore.json ]] && command -v cosign >/dev/null 2>&1; then
  echo "== подпись SHA256SUMS (cosign) =="
  cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
    --certificate-identity-regexp '^https://github.com/lct-testkit/deploy/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
else
  echo "   подпись не проверялась (нет cosign или SHA256SUMS.sigstore.json) — сверьте SHA256SUMS с опубликованным вне канала передачи"
fi

echo "== 2/5 docker load =="
gunzip -c images.tar.gz | docker load

echo "== 3/5 секреты и конфиги =="
if [[ ! -f compose/.env ]]; then
  gen_args=(--dir compose --profile "${PROFILE}")
  [[ -n "${HOST}" ]] && gen_args+=(--host "${HOST}")
  bash scripts/gen_env.sh "${gen_args[@]}"
else
  echo "   compose/.env уже есть — не трогаю"
fi
cp env/images.bundle.env compose/.env.images

if [[ "${WITH_REGISTRY}" == 1 ]]; then
  echo "== внутренний registry =="
  docker compose -f compose/docker-compose.yml --env-file compose/.env --env-file compose/.env.images \
    --profile registry up -d local-registry
  for _ in $(seq 1 30); do curl -fsS http://localhost:5000/v2/ >/dev/null 2>&1 && break; sleep 1; done
  bash scripts/registry_load.sh localhost:5000 images.tsv
fi

if [[ "${START}" == 0 ]]; then
  echo "== --no-start: стек не запускаю. Запуск: cd compose && docker compose --env-file .env --env-file .env.images up -d --wait =="
  exit 0
fi

echo "== 4/5 docker compose up =="
docker compose -f compose/docker-compose.yml --env-file compose/.env --env-file compose/.env.images up -d --wait --wait-timeout 300 --pull never

echo "== 5/5 smoke =="
bash scripts/smoke.sh "http://localhost:$(grep -E '^HTTP_PORT=' compose/.env | cut -d= -f2)"

echo
echo "готово: http://${HOST:-localhost}:$(grep -E '^HTTP_PORT=' compose/.env | cut -d= -f2)"
