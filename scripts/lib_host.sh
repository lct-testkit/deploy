#!/usr/bin/env bash
# Общие функции адреса и режима TLS для gen_env.sh, set_host.sh и install.sh. Подключается через `source`,
# сам ничего не делает. Только bash, sed, grep, tr: скрипты едут в офлайн-бандл на минимальные серверы.
#
# Режимы TLS (`TLS_MODE` в .env):
#   off       локальный стенд (по умолчанию): http://ХОСТ:HTTP_PORT, https://ХОСТ:HTTPS_PORT с самоподписанным сертификатом
#   internal  закрытый контур: HTTPS на 443, самоподписанный сертификат Caddy (для IP и внутренних имён)
#   acme      публичный домен: HTTPS на 443, сертификат Let's Encrypt (нужны DNS на этот сервер и порты 80/443 из интернета)
#
# Что задаёт режим, описано в compose/.env.example (блок «Режим TLS») и в compose/Caddyfile.

# Имя (DNS) или IPv4: буквы, цифры, точки и дефисы; не начинается и не кончается точкой/дефисом.
rtk_valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

rtk_is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# rtk_tls_default_for_host <хост> — какой режим предложить: off | internal | acme.
rtk_tls_default_for_host() {
  local host="${1:-}"
  case "${host}" in
    ''|localhost|127.*|::1) echo off; return ;;
  esac
  # Для IP Let's Encrypt сертификат не выдаёт.
  if rtk_is_ipv4 "${host}"; then echo internal; return; fi
  case "${host}" in
    *.local|*.lan|*.internal|*.intranet|*.corp|*.home|*.test|*.example|*.invalid|*.localhost|*.localdomain)
      echo internal; return ;;
  esac
  # Имя из одной метки (crm, intranet-crm) снаружи не резолвится.
  if [[ "${host}" != *.* ]]; then echo internal; return; fi
  echo acme
}

# rtk_check_mode <режим> <хост> <port-offset> — проверка сочетания параметров; сообщение в stderr, код 1 при ошибке.
rtk_check_mode() {
  local mode="$1" host="$2" offset="$3"
  case "${mode}" in
    off|internal|acme) ;;
    *) echo "--tls: off|internal|acme" >&2; return 1 ;;
  esac
  if [[ -n "${host}" ]] && ! rtk_valid_host "${host}"; then
    echo "--host '${host}': допустимы буквы, цифры, точки и дефисы (имя или IPv4)" >&2
    return 1
  fi
  if [[ "${mode}" != off ]]; then
    if [[ -z "${host}" || "${host}" == localhost ]]; then
      echo "--tls ${mode} требует --host <имя или IP сервера>: это адрес, по которому систему открывают" >&2
      return 1
    fi
    if [[ "${offset}" != 0 ]]; then
      echo "--tls ${mode}: --port-offset недопустим (порты 80/443/8333 фиксированы, такой стенд на машине один)" >&2
      return 1
    fi
  fi
  if [[ "${mode}" == acme ]]; then
    if rtk_is_ipv4 "${host}" || [[ "${host}" != *.* ]]; then
      echo "--tls acme: для IP и имён без точки Let's Encrypt сертификат не выдаёт. Используйте --tls internal" >&2
      return 1
    fi
  fi
}

# rtk_env_set <файл> <ключ> <значение> — заменяет `КЛЮЧ=...`, а если ключа нет, дописывает в конец.
rtk_env_set() {
  local file="$1" key="$2" value="$3" escaped
  escaped="$(printf '%s' "${value}" | sed -e 's/[\\&|]/\\&/g')"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

# rtk_apply_mode_env <файл .env> <режим> <хост> <port-offset>
# Пишет в .env всё, что зависит от режима и адреса (порты, URL, TLS-переменные Caddy). Сочетание параметров
# заранее проверяет rtk_check_mode. После вызова в переменных RTK_BASE_URL, RTK_HTTP_PORT, RTK_HTTPS_PORT — итог.
rtk_apply_mode_env() {
  local file="$1" mode="$2" host="$3" offset="$4"
  local pub="${host:-localhost}" http_port https_port s3_port base s3_url snippet

  rtk_env_set "${file}" TLS_MODE "${mode}"
  rtk_env_set "${file}" CRM_TLS_HOST "${pub}"
  if [[ "${mode}" == off ]]; then
    http_port=$((8080 + offset)); https_port=$((8443 + offset)); s3_port=$((8333 + offset))
    base="http://${pub}:${http_port}"
    s3_url="http://${pub}:${s3_port}"
    rtk_env_set "${file}" CRM_TLS_PORT 8443
    rtk_env_set "${file}" CRM_TLS_SNIPPET tls_internal
    rtk_env_set "${file}" S3_SITE_ADDRESS ":8333"
    rtk_env_set "${file}" S3_TLS_SNIPPET tls_none
    rtk_env_set "${file}" HTTP_BIND 0.0.0.0
    rtk_env_set "${file}" CRM_PORT80_PUBLISH "127.0.0.1::80"
  else
    http_port=8080; https_port=443; s3_port=8333
    base="https://${pub}"
    s3_url="https://${pub}:${s3_port}"
    snippet=tls_internal
    [[ "${mode}" == acme ]] && snippet=tls_acme
    rtk_env_set "${file}" CRM_TLS_PORT 443
    rtk_env_set "${file}" CRM_TLS_SNIPPET "${snippet}"
    rtk_env_set "${file}" S3_SITE_ADDRESS "${pub}:${s3_port}"
    rtk_env_set "${file}" S3_TLS_SNIPPET "${snippet}"
    # plain-http :8080 остаётся только на loopback: Docker публикует порты в обход ufw.
    rtk_env_set "${file}" HTTP_BIND 127.0.0.1
    rtk_env_set "${file}" CRM_PORT80_PUBLISH "80:80"
  fi
  rtk_env_set "${file}" HTTP_PORT "${http_port}"
  rtk_env_set "${file}" HTTPS_PORT "${https_port}"
  rtk_env_set "${file}" S3_PROXY_PORT "${s3_port}"
  rtk_env_set "${file}" POSTGRES_PORT "$((5433 + offset))"
  rtk_env_set "${file}" BASE_URL "${base}"
  rtk_env_set "${file}" KEYCLOAK_URL "${base}/auth"
  rtk_env_set "${file}" KEYCLOAK_PUBLIC_URL "${base}/auth"
  rtk_env_set "${file}" S3_PUBLIC_ENDPOINT_URL "${s3_url}"
  # Результат для вызывающих скриптов (gen_env.sh, set_host.sh): в самом файле они не читаются.
  # shellcheck disable=SC2034
  RTK_BASE_URL="${base}" RTK_HTTP_PORT="${http_port}" RTK_HTTPS_PORT="${https_port}"
}

# rtk_render_realm <шаблон realm> <результат> <секрет crm-bff> <секрет crm-admin> <режим> <хост> <http_port> <https_port>
# Realm с секретами стенда и адресами клиента crm-bff (redirectUris, webOrigins, post.logout.redirect.uris).
#   off:            localhost:8080 / localhost:8443 заменяются на ХОСТ:порты стенда (как раньше);
#   internal/acme:  localhost-адреса остаются (доступ с самого сервера), публичный https://ХОСТ ДОБАВЛЯЕТСЯ рядом.
# Импорт realm выполняется один раз, при создании БД Keycloak: у уже установленного стенда правка файла ничего не
# меняет, адреса в БД правит scripts/set_host.sh. Результат читает Keycloak под другим UID, права ставит вызывающий.
rtk_render_realm() {
  local src="$1" dst="$2" bff="$3" adm="$4" mode="$5" host="$6" http_port="$7" https_port="$8"
  local pub="${host:-localhost}" tmp origin
  tmp="$(mktemp)"
  tr -d '\r' < "${src}" | sed -e "s|crm-bff-secret|${bff}|g" -e "s|crm-admin-secret|${adm}|g" > "${tmp}"
  if [[ "${mode}" == off ]]; then
    sed -i -e "s|//localhost:8080|//${pub}:${http_port}|g" -e "s|//localhost:8443|//${pub}:${https_port}|g" "${tmp}"
  else
    origin="https://${pub}"
    sed -i \
      -e "s|^\( *\)\"http://localhost:8080/\*\",\$|&\n\1\"${origin}/*\",|" \
      -e "s|^\( *\)\"http://localhost:8080\",\$|&\n\1\"${origin}\",|" \
      -e "s|\"post.logout.redirect.uris\": \"|&${origin}/*##|" \
      "${tmp}"
    grep -q "\"${origin}/\*\"" "${tmp}" || { echo "realm: не удалось добавить ${origin}/* (структура realm-crm.json изменилась?)" >&2; rm -f "${tmp}"; return 1; }
  fi
  mv "${tmp}" "${dst}"
}
