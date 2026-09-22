#!/usr/bin/env bash
# Собирает офлайн-поставку: один архив с образами (docker save) + compose-
# профиль + инструкция по установке — для контура без доступа к GHCR/Docker
# Hub в рантайме (rtk_requiriments.md — весь сервис рассчитан на закрытый
# контур, а не только рантайм-часть compose уже собранного стенда).
#
# Тянет образы по images.yaml (registry.host/project + tag/digest, external.*
# по digest) — не по тому, что случайно лежит в локальном кеше Docker,
# поэтому воспроизводим на чистой машине с доступом в интернет/GHCR.
#
#   scripts/build_offline_bundle.sh [версия] [--allow-missing]
#
# версия по умолчанию — короткий sha HEAD. --allow-missing пропускает (с
# предупреждением, не ошибкой) образы, у которых в images.yaml ещё пуст tag —
# полезно для локальной проверки механики сборки бандла до первого реального
# пуша backend/frontend в GHCR; для настоящей офлайн-поставки не передавайте
# этот флаг — бандл без api/web бесполезен.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# Debian/Ubuntu (целевые серверы, см. RUNBOOK.md) ставят именно `python3`;
# `python` без суффикса на них зачастую нет вовсе. На машине разработки
# (Windows/Git Bash и т.п.) обычно наоборот — берём что реально есть.
PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"

ALLOW_MISSING=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --allow-missing) ALLOW_MISSING=1 ;;
    *) VERSION="$arg" ;;
  esac
done
VERSION="${VERSION:-sha-$(git rev-parse --short=7 HEAD)}"

OUT_DIR="$(mktemp -d)"
BUNDLE_NAME="rtk-crm-offline-${VERSION}"
STAGE="${OUT_DIR}/${BUNDLE_NAME}"
mkdir -p "${STAGE}/compose"

log() { echo "[bundle] $*"; }

log "версия: ${VERSION}, сборка во временном каталоге ${STAGE}"

# --- 1. Список образов из images.yaml -------------------------------------
mapfile -t REFS < <("$PY" - "$ALLOW_MISSING" <<'PY' | tr -d '\r'
import sys
import yaml

allow_missing = sys.argv[1] == "1"
doc = yaml.safe_load(open("images.yaml", encoding="utf-8"))
registry = doc["registry"]
missing = []

for name, spec in doc.get("images", {}).items():
    tag = spec.get("tag", "")
    if not tag:
        missing.append(f"images.{name}")
        continue
    print(f"{registry['host']}/{registry['project']}/{name}:{tag}")

for name, spec in doc.get("external", {}).items():
    ref, digest = spec.get("ref", ""), spec.get("digest", "")
    if not digest:
        missing.append(f"external.{name}")
        continue
    base = ref.rsplit(":", 1)[0]
    print(f"{base}@{digest}")

if missing and not allow_missing:
    print("нет tag/digest: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if missing:
    print("WARN пропущены (--allow-missing): " + ", ".join(missing), file=sys.stderr)
PY
)

if [[ ${#REFS[@]} -eq 0 ]]; then
  echo "images.yaml: ни одного образа с заполненным tag/digest — нечего паковать" >&2
  exit 1
fi

log "образов к упаковке: ${#REFS[@]}"

# --- 2. Pull + save ---------------------------------------------------------
for ref in "${REFS[@]}"; do
  if ! docker image inspect "${ref}" >/dev/null 2>&1; then
    log "docker pull ${ref}"
    docker pull "${ref}"
  else
    log "уже есть локально: ${ref}"
  fi
done

log "docker save -> images.tar (все ${#REFS[@]} образов одним архивом)"
docker save -o "${STAGE}/images.tar" "${REFS[@]}"
gzip -f "${STAGE}/images.tar"

# --- 3. compose-профиль + вспомогательные файлы -----------------------------
cp compose/docker-compose.yml "${STAGE}/compose/"
cp compose/.env.example "${STAGE}/compose/"
cp compose/Caddyfile "${STAGE}/compose/"
cp -r compose/postgres compose/seaweedfs compose/keycloak "${STAGE}/compose/" 2>/dev/null || true

cat > "${STAGE}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Установка на машине БЕЗ доступа в интернет: docker/docker-compose-plugin
# уже должны быть установлены (см. RUNBOOK.md «Офлайн-установка»).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== docker load =="
gunzip -k images.tar.gz
docker load -i images.tar

echo "== .env =="
if [[ ! -f compose/.env ]]; then
  cp compose/.env.example compose/.env
  echo "compose/.env создан из .env.example — ОБЯЗАТЕЛЬНО смените пароли/секреты перед боевой эксплуатацией (RUNBOOK.md «Перед боевым контуром»)"
fi

echo "== docker compose up =="
docker compose -f compose/docker-compose.yml --env-file compose/.env up -d

echo "готово: http://localhost:8080"
EOF
chmod +x "${STAGE}/install.sh"

cat > "${STAGE}/README.md" <<EOF
# RTK School CRM — офлайн-поставка ${VERSION}

Установка на машине без доступа в интернет/GHCR:

\`\`\`bash
bash install.sh
\`\`\`

Разворачивает тот же стек, что и живой демо-стенд (Caddy, API, worker,
Keycloak, PostgreSQL, Redis, SeaweedFS) — образы уже внутри \`images.tar.gz\`,
сеть не нужна. Подробности, чек-лист секретов перед боевой эксплуатацией и
устранение неполадок — \`RUNBOOK.md\` в основном репозитории \`deploy\`
(скопируйте отдельно, в бандл не входит, чтобы не дублировать документацию,
которая может обновиться между релизами).
EOF

# --- 4. Финальный архив ------------------------------------------------------
FINAL="${REPO_DIR}/${BUNDLE_NAME}.tar.gz"
tar -C "${OUT_DIR}" -czf "${FINAL}" "${BUNDLE_NAME}"
rm -rf "${OUT_DIR}"

log "готово: ${FINAL} ($(du -h "${FINAL}" | cut -f1))"
