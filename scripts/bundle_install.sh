#!/usr/bin/env bash
# Установка RTK School CRM из офлайн-бандла на машине БЕЗ доступа в интернет.
# Копируется в бандл как install.sh. Нужны только Docker и плагин docker compose.
#
#   bash install.sh [--profile demo|prod] [--host <имя/IP>] [--tls acme|internal|off]
#                   [--seed | --no-seed] [--fonts <каталог>] [--yes] [--port-offset N]
#                   [--open-firewall] [--skip-dns-check] [--reconfigure] [--registry] [--no-start]
#
#   --profile      окружение: demo (по умолчанию) или prod (APP_PROFILE и APP_MODE=prod). Синоним: --env
#   --host         адрес, по которому открывают систему (имя или IP): BASE_URL, Keycloak, S3, сертификат. Для prod обязателен
#   --tls          как отдаём систему: acme — HTTPS на 443, сертификат Let's Encrypt (публичный домен, DNS на этот сервер,
#                  порты 80/443 из интернета); internal — HTTPS на 443, самоподписанный сертификат (закрытый контур, IP,
#                  внутренние имена); off — без публичного TLS, http://ХОСТ:8080 и https://ХОСТ:8443 (локально, тест).
#                  По умолчанию выводится из адреса: домен -> acme, IP и внутренние имена -> internal, localhost -> off
#   --seed         залить моковые данные (организации, контакты, сделки, задачи, ЕГРЮЛ, справочники, праздники,
#                  сценарии удаления ПДн). Только demo; для demo включено по умолчанию
#   --no-seed      поставить чистую систему без моковых данных
#   --fonts        каталог с *.woff шрифтами Rostelecom Basis (лицензионные, если не вошли в бандл: compose/fonts)
#   --yes          ничего не спрашивать. Без него в терминале установщик задаёт вопросы про окружение, адрес, TLS, шрифты
#                  и моковые данные, показывает сводку и ждёт подтверждения
#   --port-offset  сдвиг портов (8080+N, 8443+N, 8333+N, 5433+N) для нескольких стендов на одной машине (только --tls off)
#   --open-firewall  открыть в ufw порты 80/443/8333, если ufw активен и они закрыты (в терминале спросит сам)
#   --skip-dns-check не проверять, что имя (для acme) указывает на этот сервер
#   --reconfigure  не устанавливать, а сменить адрес/режим TLS у установленного стенда (то же, что scripts/set_host.sh)
#   --registry     поднять внутренний registry (localhost:5000) и залить в него образы
#   --no-start     только проверить, загрузить образы и создать .env, стек не запускать
#
# Без терминала (CI, ssh без tty) вопросов нет: берутся флаги и значения по умолчанию
# (demo, localhost, без TLS, моковые данные включены).
#
# Порядок: параметры и проверки → SHA256SUMS → (подпись, если есть cosign) → docker load → секреты →
# compose up --wait → smoke → моковые данные. На любом расхождении контрольных сумм установка
# прерывается ДО загрузки образов.
set -euo pipefail
# Путь к самому себе запоминаем до cd: иначе --help не найдёт файл при запуске по относительному пути.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${SELF}")"
# shellcheck source=scripts/lib_host.sh
source scripts/lib_host.sh

PROFILE=""
HOST=""
TLS=""
SEED=""
FONTS_SRC=""
ASSUME_YES=0
PORT_OFFSET=0
OPEN_FW=0
SKIP_DNS=0
RECONFIGURE=0
WITH_REGISTRY=0
START=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|--env) PROFILE="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --tls) TLS="${2:-}"; shift 2 ;;
    --seed) SEED=1; shift ;;
    --no-seed) SEED=0; shift ;;
    --fonts) FONTS_SRC="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --port-offset) PORT_OFFSET="${2:-}"; shift 2 ;;
    --open-firewall) OPEN_FW=1; shift ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --registry) WITH_REGISTRY=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p}' "${SELF}"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ОШИБКА: $*" >&2; exit 2; }

# Вопросы задаём, только если есть живой терминал и не просили --yes.
INTERACTIVE=0
if [[ "${ASSUME_YES}" != 1 && -t 0 && -t 1 ]]; then INTERACTIVE=1; fi

# ask_yn <вопрос> <y|n — ответ по умолчанию>: код 0 = да. На конец ввода (EOF) берётся ответ по умолчанию.
ask_yn() {
  local question="$1" default="$2" answer hint
  if [[ "${default}" == y ]]; then hint="Y/n"; else hint="y/N"; fi
  while :; do
    read -r -p "${question} [${hint}]: " answer || answer=""
    case "$(printf '%s' "${answer:-${default}}" | tr '[:upper:]' '[:lower:]')" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
    echo "  ответьте y или n" >&2
  done
}

choose_profile() {
  local answer
  echo "Окружение:"
  echo "  1) demo — демо-стенд: демо-учётки на экране входа, можно залить моковые данные"
  echo "  2) prod — боевое: случайные секреты, без демо-входа и без моковых данных"
  while :; do
    read -r -p "Выбор [1]: " answer || answer=""
    case "${answer:-1}" in
      1|demo) PROFILE=demo; return ;;
      2|prod) PROFILE=prod; return ;;
    esac
    echo "  введите 1 или 2" >&2
  done
}

choose_host() {
  local default="localhost" answer
  [[ "${PROFILE}" == prod ]] && default=""
  while :; do
    read -r -p "Адрес системы: имя или IP сервера, по которому её будут открывать${default:+ [${default}]}: " answer \
      || { [[ -n "${default}" ]] && answer="" || die "не задан адрес сервера (--host)"; }
    answer="${answer:-${default}}"
    if [[ -z "${answer}" ]]; then echo "  для prod адрес обязателен" >&2; continue; fi
    if rtk_valid_host "${answer}"; then HOST="${answer}"; return; fi
    echo "  допустимы буквы, цифры, точки и дефисы (имя или IPv4)" >&2
  done
}

choose_tls() {
  local suggested answer
  suggested="$(rtk_tls_default_for_host "${HOST}")"
  echo "Как отдаём систему (TLS):"
  echo "  1) acme     — HTTPS на 443, сертификат Let's Encrypt. Нужны публичный домен, DNS на этот сервер, порты 80/443 из интернета"
  echo "  2) internal — HTTPS на 443, самоподписанный сертификат. Для закрытого контура, IP-адреса, внутренних имён"
  echo "  3) off      — без публичного TLS: http://${HOST:-localhost}:8080 и https://${HOST:-localhost}:8443. Только локально/тест"
  local def=3
  case "${suggested}" in acme) def=1 ;; internal) def=2 ;; esac
  while :; do
    read -r -p "Выбор [${def}]: " answer || answer=""
    case "${answer:-${def}}" in
      1|acme) TLS=acme; return ;;
      2|internal) TLS=internal; return ;;
      3|off) TLS=off; return ;;
    esac
    echo "  введите 1, 2 или 3" >&2
  done
}

# Каталог шрифтов: пусто = без шрифта. Проверяем, что внутри есть *.woff.
choose_fonts() {
  local answer
  while :; do
    read -r -p "Каталог со шрифтами Rostelecom Basis (*.woff), пусто — без шрифта (запасная гарнитура): " answer || answer=""
    [[ -n "${answer}" ]] || return 0
    if [[ -d "${answer}" ]] && compgen -G "${answer}/*.woff*" >/dev/null; then FONTS_SRC="${answer}"; return; fi
    echo "  в '${answer}' нет каталога или файлов *.woff/*.woff2" >&2
  done
}

command -v docker >/dev/null || { echo "docker не найден" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "плагин 'docker compose' не найден" >&2; exit 1; }

# --- параметры установки -----------------------------------------------------
case "${PORT_OFFSET}" in ''|*[!0-9]*) die "--port-offset: нужно неотрицательное целое" ;; esac
[[ -z "${PROFILE}" ]] || case "${PROFILE}" in demo|prod) ;; *) die "--profile: demo|prod" ;; esac
[[ -z "${HOST}" ]] || rtk_valid_host "${HOST}" || die "--host '${HOST}': допустимы буквы, цифры, точки и дефисы (имя или IPv4)"
[[ -z "${TLS}" ]] || case "${TLS}" in off|internal|acme) ;; *) die "--tls: off|internal|acme" ;; esac
if [[ -n "${FONTS_SRC}" ]]; then
  [[ -d "${FONTS_SRC}" ]] && compgen -G "${FONTS_SRC}/*.woff*" >/dev/null || die "--fonts: в '${FONTS_SRC}' нет каталога или файлов *.woff/*.woff2"
fi

if [[ "${RECONFIGURE}" == 1 ]]; then
  [[ -f compose/.env ]] || die "--reconfigure: стенд не установлен (нет compose/.env)"
  [[ -n "${HOST}" ]] || die "--reconfigure: нужен --host"
  reconf_args=(--host "${HOST}")
  [[ -n "${TLS}" ]] && reconf_args+=(--tls "${TLS}")
  exec bash scripts/set_host.sh "${reconf_args[@]}"
fi

EXISTING_ENV=0
if [[ -f compose/.env ]]; then
  # Секреты и адрес уже сгенерированы: не перегенерируем (тома БД хранят прежние пароли). Окружение, адрес и режим берём из .env.
  EXISTING_ENV=1
  env_get() { grep -E "^$1=" compose/.env | tail -1 | cut -d= -f2- || true; }
  env_profile="$(env_get APP_PROFILE)"
  env_base="$(env_get BASE_URL)"
  env_host="${env_base#*://}"; env_host="${env_host%%[:/]*}"
  env_tls="$(env_get TLS_MODE)"; env_tls="${env_tls:-off}"
  if [[ -n "${PROFILE}" && "${PROFILE}" != "${env_profile:-demo}" ]]; then
    die "compose/.env создан для окружения '${env_profile:-demo}', а запрошено '${PROFILE}'. Смена окружения = новая установка: удалите compose/.env (и тома стека: docker compose down -v) и запустите заново"
  fi
  if [[ ( -n "${HOST}" && "${HOST}" != "${env_host}" ) || ( -n "${TLS}" && "${TLS}" != "${env_tls}" ) ]]; then
    die "адрес и режим TLS уже зафиксированы в compose/.env (${env_host}, TLS ${env_tls}). Сменить их у установленного стенда: bash install.sh --reconfigure --host <имя> --tls <режим> (или scripts/set_host.sh)"
  fi
  PROFILE="${env_profile:-demo}"
  HOST="${env_host}"
  TLS="${env_tls}"
  http_port="$(env_get HTTP_PORT)"
  https_port="$(env_get HTTPS_PORT)"
  echo "   compose/.env уже есть: окружение (${PROFILE}), адрес (${HOST}) и режим TLS (${TLS}) беру из него"
else
  if [[ -z "${PROFILE}" ]]; then
    if [[ "${INTERACTIVE}" == 1 ]]; then choose_profile; else PROFILE=demo; fi
  fi
  if [[ -z "${HOST}" ]]; then
    if [[ "${INTERACTIVE}" == 1 ]]; then
      choose_host
    elif [[ "${PROFILE}" == prod ]]; then
      die "для prod нужен --host <имя/IP сервера>: без него BASE_URL остаётся localhost и вход не заработает с других машин"
    else
      echo "   адрес не задан — ставлю на localhost (для доступа с других машин: --host <имя/IP>)"
    fi
  fi
  if [[ -z "${TLS}" ]]; then
    if [[ "${INTERACTIVE}" == 1 ]]; then choose_tls; else TLS="$(rtk_tls_default_for_host "${HOST}")"; fi
  fi
  rtk_check_mode "${TLS}" "${HOST}" "${PORT_OFFSET}" || exit 2
  if [[ "${TLS}" == off ]]; then
    http_port=$((8080 + PORT_OFFSET)); https_port=$((8443 + PORT_OFFSET))
  else
    http_port=8080; https_port=443
  fi
  if [[ -z "${FONTS_SRC}" && "${INTERACTIVE}" == 1 ]] && ! compgen -G "compose/fonts/*.woff*" >/dev/null; then
    choose_fonts
  fi
fi

# Моковые данные: только demo. В prod вход по Bearer ограничен ролью INTEGRATION, а /config.json не отдаёт секрет клиента.
if [[ "${PROFILE}" == prod ]]; then
  [[ "${SEED}" != 1 ]] || die "--seed только для demo: в prod моковые данные не заливаются"
  SEED=0
elif [[ -z "${SEED}" ]]; then
  if [[ "${INTERACTIVE}" == 1 ]]; then
    if ask_yn "Залить моковые данные (организации, контакты, сделки, задачи, ЕГРЮЛ, справочники, праздники)?" y; then SEED=1; else SEED=0; fi
  else
    SEED=1
  fi
fi

SHOW_HOST="${HOST:-localhost}"
case "${TLS}" in
  acme) address_label="https://${SHOW_HOST}  (сертификат Let's Encrypt; http перенаправляется на https)" ;;
  internal) address_label="https://${SHOW_HOST}  (самоподписанный сертификат: браузер покажет предупреждение)" ;;
  *) address_label="http://${SHOW_HOST}:${http_port}  (и https://${SHOW_HOST}:${https_port}, самоподписанный сертификат)" ;;
esac
seed_label="нет (чистая система)"
[[ "${SEED}" == 1 ]] && seed_label="да (справочники, организации, сделки, задачи, ЕГРЮЛ, праздники)"
fonts_label="нет: интерфейс на запасной гарнитуре (файлы *.woff можно добавить позже, см. RUNBOOK)"
if [[ -n "${FONTS_SRC}" ]]; then
  fonts_label="из ${FONTS_SRC}"
elif compgen -G "compose/fonts/*.woff*" >/dev/null; then
  fonts_label="из бандла (compose/fonts, $(find compose/fonts -name '*.woff*' | wc -l) файл(ов))"
fi
echo
echo "== параметры установки =="
echo "   окружение:       ${PROFILE}"
echo "   адрес:           ${address_label}"
echo "   режим TLS:       ${TLS}"
echo "   шрифты:          ${fonts_label}"
echo "   моковые данные:  ${seed_label}"

# --- предполётные проверки публичных режимов: до docker load, он долгий -------------------
# Только свежая установка (иначе порты заняты нашим же стеком) и только если стек будем запускать.
preflight_public() {
  local port owner missing=() fw_cmds=() answer
  if command -v ss >/dev/null 2>&1; then
    for port in 80 443 8333; do
      if ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        owner="$(ss -ltnp "sport = :${port}" 2>/dev/null | awk 'NR==2 {print $NF}')"
        die "порт ${port} на сервере уже занят (${owner:-неизвестный процесс}): для --tls ${TLS} нужны свободные 80, 443 и 8333"
      fi
    done
  else
    echo "   предупреждение: нет утилиты ss, свободность портов 80/443/8333 не проверена"
  fi

  if [[ "${TLS}" == acme ]]; then
    local resolved public_ip
    resolved="$(getent hosts "${HOST}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    if [[ -z "${resolved}" ]]; then
      if [[ "${SKIP_DNS}" == 1 ]]; then echo "   предупреждение: имя ${HOST} не резолвится (проверка отключена --skip-dns-check)"
      else die "имя ${HOST} не резолвится. Создайте A-запись на IP этого сервера или используйте --tls internal (проверку можно отключить: --skip-dns-check)"; fi
    else
      public_ip="$(curl -fsS -m 5 https://ifconfig.me 2>/dev/null || true)"
      if [[ -n "${public_ip}" && "${public_ip}" != "${resolved}" ]]; then
        echo "   ПРЕДУПРЕЖДЕНИЕ: ${HOST} указывает на ${resolved}, а внешний адрес этого сервера ${public_ip}: Let's Encrypt не сможет пройти проверку"
      else
        echo "   DNS: ${HOST} -> ${resolved}${public_ip:+ (внешний адрес сервера ${public_ip})}"
      fi
    fi
    if ! curl -fsS -m 8 -o /dev/null https://acme-v02.api.letsencrypt.org/directory 2>/dev/null; then
      echo "   ПРЕДУПРЕЖДЕНИЕ: нет доступа к Let's Encrypt (acme-v02.api.letsencrypt.org). Сертификат не выпустится; в закрытом контуре используйте --tls internal"
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for port in 80 443 8333; do
      ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW" || missing+=("${port}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      for port in "${missing[@]}"; do fw_cmds+=("ufw allow ${port}/tcp"); done
      echo "   ufw активен и не пропускает порты: ${missing[*]}. Нужно: ${fw_cmds[*]}"
      if [[ "${OPEN_FW}" == 1 ]]; then
        answer=y
      elif [[ "${INTERACTIVE}" == 1 ]]; then
        if ask_yn "Открыть их сейчас?" y; then answer=y; else answer=n; fi
      else
        answer=n; echo "   (не открываю без --open-firewall; выполните команды выше вручную)"
      fi
      if [[ "${answer}" == y ]]; then
        for port in "${missing[@]}"; do ufw allow "${port}/tcp" >/dev/null && echo "   открыт ${port}/tcp"; done
      fi
    fi
  fi
}

if [[ "${EXISTING_ENV}" == 0 && "${START}" == 1 && "${TLS}" != off ]]; then
  echo
  echo "== проверка сервера для --tls ${TLS} =="
  preflight_public
fi

if [[ "${INTERACTIVE}" == 1 ]]; then
  echo
  ask_yn "Продолжить установку?" y || { echo "отменено"; exit 1; }
fi

echo
echo "== 1/6 проверка контрольных сумм =="
sha256sum --quiet -c SHA256SUMS || { echo "ОШИБКА: контрольные суммы не сошлись — бандл повреждён или изменён" >&2; exit 1; }
echo "   SHA256SUMS: ок ($(wc -l < SHA256SUMS) файлов)"

# release.yml подписывает не SHA256SUMS (она только внутри бандла), а контрольную сумму самого
# архива — <имя-бандла>.tar.gz.sha256 / .sigstore.json, отдельными файлами релиза рядом с
# архивом (RUNBOOK «Офлайн-установка»). Распакованный бандл — это каталог с тем же именем, что
# и архив (build_offline_bundle.sh: `tar -C … -czf "${NAME}.tar.gz" "${NAME}"`), поэтому если
# архив распаковали там же, где скачали (обычный сценарий), эти файлы лежат рядом, уровнем выше.
bundle_name="$(basename "$PWD")"
sums_sig="../${bundle_name}.tar.gz.sha256.sigstore.json"
sums_file="../${bundle_name}.tar.gz.sha256"
if [[ -f "${sums_sig}" && -f "${sums_file}" ]] && command -v cosign >/dev/null 2>&1; then
  echo "== подпись архива (cosign) =="
  cosign verify-blob "${sums_file}" --bundle "${sums_sig}" \
    --certificate-identity-regexp '^https://github.com/lct-testkit/deploy/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  echo "   подпись архива: ок"
else
  echo "   подпись архива не проверена автоматически (нет cosign или архив/.sha256/.sigstore.json не лежат рядом с распакованным каталогом) —"
  echo "   сверьте вручную командой из RUNBOOK.md («Офлайн-установка») или из описания релиза"
fi

echo "== 2/6 docker load =="
gunzip -c images.tar.gz | docker load

echo "== 3/6 секреты и конфиги =="
if [[ ! -f compose/.env ]]; then
  gen_args=(--dir compose --profile "${PROFILE}" --tls "${TLS}" --port-offset "${PORT_OFFSET}")
  [[ -n "${HOST}" ]] && gen_args+=(--host "${HOST}")
  [[ -n "${FONTS_SRC}" ]] && gen_args+=(--fonts "${FONTS_SRC}")
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
  [[ "${SEED}" == 1 ]] && echo "   Моковые данные после запуска: bash scripts/seed_demo.sh"
  exit 0
fi

echo "== 4/6 docker compose up =="
docker compose -f compose/docker-compose.yml --env-file compose/.env --env-file compose/.env.images up -d --wait --wait-timeout 300 --pull never

echo "== 5/6 smoke =="
LOCAL_HTTP_PORT="$(grep -E '^HTTP_PORT=' compose/.env | cut -d= -f2)"
bash scripts/smoke.sh "http://localhost:${LOCAL_HTTP_PORT}"
if [[ "${TLS}" != off ]]; then
  # Публичный адрес по HTTPS: у acme сертификат выпускается при первом обращении, smoke ждёт его до 5 минут.
  public_smoke_args=(--timeout 300)
  [[ "${TLS}" == internal ]] && public_smoke_args+=(--insecure)
  bash scripts/smoke.sh "https://${HOST}" "${public_smoke_args[@]}" \
    || { echo "ОШИБКА: по публичному адресу https://${HOST} система не отвечает. Логи Caddy: docker compose -f compose/docker-compose.yml --env-file compose/.env --env-file compose/.env.images logs caddy" >&2; exit 1; }
fi

SEED_FAILED=0
if [[ "${SEED}" == 1 ]]; then
  echo "== 6/6 моковые данные =="
  bash scripts/seed_demo.sh --env-file compose/.env --images-env compose/.env.images || SEED_FAILED=1
fi

FINAL_URL="$(grep -E '^BASE_URL=' compose/.env | cut -d= -f2-)"
echo
echo "готово: ${FINAL_URL}"
if [[ "${PROFILE}" == demo ]]; then
  echo "   вход: на экране входа выберите демо-учётку (администратор, руководитель, менеджер, аудитор)"
  case "${SHOW_HOST}" in
    localhost|127.*) ;;
    *)
      echo
      echo "ВНИМАНИЕ: демо-режим показывает демо-учётки и секрет клиента Keycloak на экране входа и в /config.json."
      echo "         Не открывайте такой стенд в интернет; для боевого использования: install.sh --profile prod --host ${SHOW_HOST}."
      ;;
  esac
fi
if [[ "${TLS}" == internal ]]; then
  echo
  echo "Самоподписанный сертификат: чтобы браузеры не ругались, установите корневой сертификат Caddy на клиентах:"
  echo "  docker compose -f compose/docker-compose.yml --env-file compose/.env --env-file compose/.env.images cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt"
fi
if [[ "${SEED_FAILED}" == 1 ]]; then
  echo
  echo "ОШИБКА: моковые данные залились не полностью. Система установлена; повторить (безопасно): bash scripts/seed_demo.sh" >&2
  exit 1
fi
