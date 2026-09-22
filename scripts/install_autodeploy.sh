#!/usr/bin/env bash
# Ставит systemd-таймер, который каждые 5 минут гоняет scripts/deploy.sh под
# пользователем deploy (см. provision_vm.sh). Отдельно от provision_vm.sh:
# та готовит VM один раз (docker, пользователь, каталоги, swap), эта
# настраивает именно механизм автодеплоя — логично делать после первого
# ручного деплоя (RUNBOOK.md «Первый деплой на VM»), не раньше.
#
# Идемпотентен. Запускать руками на целевой VM с правами sudo, из корня
# чекаута этого репозитория (тот же чекаут, что использует deploy.sh):
#   sudo bash scripts/install_autodeploy.sh [demo|dev]
set -euo pipefail

RTK_ENV="${1:-demo}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="rtk-${RTK_ENV}-autodeploy"

if [[ $EUID -ne 0 ]]; then
  echo "нужен root (sudo)" >&2
  exit 1
fi
if [[ ! -d "/srv/rtk-${RTK_ENV}" ]]; then
  echo "нет /srv/rtk-${RTK_ENV} — сначала scripts/provision_vm.sh" >&2
  exit 1
fi

cat > "/etc/systemd/system/${UNIT_NAME}.service" <<EOF
[Unit]
Description=RTK CRM автодеплой (${RTK_ENV})
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
User=${DEPLOY_USER}
Environment=RTK_ENV=${RTK_ENV}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/scripts/deploy.sh
# Пять минут — ощутимо дольше самого долгого шага деплоя (docker compose
# pull на медленной сети), поэтому таймаут ловит реальное зависание, а не
# обычный прогон.
TimeoutStartSec=300
EOF

cat > "/etc/systemd/system/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Таймер: ${UNIT_NAME}.service каждые 5 минут

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}.timer"

cat <<EOF

Готово. ${UNIT_NAME}.timer запущен и включён.
  systemctl status ${UNIT_NAME}.timer     — расписание
  systemctl start ${UNIT_NAME}.service    — прогнать деплой прямо сейчас
  journalctl -u ${UNIT_NAME}.service -f   — логи последнего/текущего прогона
EOF
