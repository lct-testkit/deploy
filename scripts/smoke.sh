#!/usr/bin/env bash
# Дымовая проверка поднятого стека. Только bash + curl.
#
#   bash scripts/smoke.sh [base_url] [--timeout 180] [--insecure]
#
# Проверяет то, без чего система бесполезна: балансировщик жив, API готов
# (БД/Redis доступны), фронт отдаётся, Keycloak realm импортирован и отдаёт
# JWKS, защищённые ручки не открыты без аутентификации. Код возврата != 0,
# если хоть одна проверка не прошла за отведённое время.
# --insecure: не проверять сертификат (режим TLS internal: самоподписанный сертификат Caddy).
# Шрифты Rostelecom Basis необязательны: их отсутствие даёт только предупреждение, а не провал.
set -uo pipefail

BASE="http://localhost:${HTTP_PORT:-8080}"
TIMEOUT=180
CURL_TLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --insecure) CURL_TLS=(-k); shift ;;
    http*) BASE="${1%/}"; shift ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

FAILED=0
deadline=$(( $(date +%s) + TIMEOUT ))

# check <название> <ожидаемый HTTP-код> <URL> [подстрока в теле]
# Тело и код читаются одним вызовом curl без временных файлов.
check() {
  local name="$1" want="$2" url="$3" needle="${4:-}" resp code body
  while :; do
    resp="$(curl -sS ${CURL_TLS[@]+"${CURL_TLS[@]}"} -m 10 -w '\n%{http_code}' "${url}" 2>/dev/null || true)"
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    if [[ "${code}" == "${want}" ]]; then
      if [[ -z "${needle}" ]] || grep -q -- "${needle}" <<<"${body}"; then
        echo "  ok    ${name} (${code})"
        return 0
      fi
    fi
    if (( $(date +%s) >= deadline )); then
      echo "  FAIL  ${name}: получили ${code:-нет ответа}, ждали ${want}${needle:+ и '${needle}' в теле} — ${url}"
      FAILED=1
      return 1
    fi
    sleep 3
  done
}

echo "smoke: ${BASE} (таймаут ${TIMEOUT}с)"
check "caddy/api жив"              200 "${BASE}/health/live"
check "api готов (БД, Redis)"      200 "${BASE}/health/ready"
check "фронт отдаётся"             200 "${BASE}/" "<html"
check "фронт: /config.json"        200 "${BASE}/config.json"
check "OpenAPI-схема"              200 "${BASE}/api/openapi.json" '"openapi"'
check "Keycloak: realm импортирован" 200 "${BASE}/auth/realms/crm/.well-known/openid-configuration" "issuer"
check "Keycloak: JWKS"             200 "${BASE}/auth/realms/crm/protocol/openid-connect/certs" '"keys"'
check "защита: /api/deals без сессии" 401 "${BASE}/api/deals"

# Шрифты: только предупреждение. Если файла нет, SPA-fallback отвечает HTML-заглушкой (или Caddy 404), и интерфейс
# работает на запасной гарнитуре.
font_type="$(curl -sS ${CURL_TLS[@]+"${CURL_TLS[@]}"} -m 10 -o /dev/null -w '%{content_type}' "${BASE}/fonts/RostelecomBasis-Regular.woff" 2>/dev/null || true)"
case "${font_type}" in
  font/*|application/font*|application/x-font*|application/octet-stream) echo "  ok    шрифты Rostelecom Basis (${font_type})" ;;
  *) echo "  warn  шрифты Rostelecom Basis не найдены (${font_type:-нет ответа}): интерфейс на запасной гарнитуре. Положите *.woff в compose/fonts/ (см. RUNBOOK)" ;;
esac

if [[ "${FAILED}" -ne 0 ]]; then
  echo "smoke: ПРОВАЛ"
  exit 1
fi
echo "smoke: всё в порядке"
