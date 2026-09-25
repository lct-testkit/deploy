# RUNBOOK — эксплуатация RTK School CRM

Как поднять систему на реальном сервере (не на машине разработчика — для этого есть `backend/docker-compose.yml`, см. корневой README) и поддерживать её: конвейер поставки, провижининг VM, первый деплой, автодеплой, откат, офлайн-установка, бэкап/восстановление, Kubernetes. Все команды — с целевого сервера (Ubuntu/Debian, systemd), если не сказано иное.

## Конвейер поставки (CI/CD целиком)

```
backend / frontend / rt-ui                                 deploy
─────────────────────────                                  ──────
PR  → lint · типы · тесты (+Postgres) · миграции ·          PR → yamllint · actionlint · shellcheck ·
      контракт API · pip/npm audit · Trivy fs ·                  hadolint · compose config · helm lint ·
      hadolint                                                   drift-проверка · e2e (стенд из образов)
main → те же гейты, затем публикация образа:
      build → Trivy → push → SBOM+provenance → cosign ──dispatch──► notify.yml:
      (образ в GHCR только после чистого скана)                       1. образ есть в GHCR, digest = тег
                                                                       2. стек с НОВЫМ образом поднимается, smoke зелёный
                                                                       3. только после этого — коммит в images.yaml
                                                                  автодеплой (VM, таймер) → бэкап → up --wait → smoke →
                                                                       при провале — откат образов
                                                                  тег vX.Y.Z → e2e (в т.ч. офлайн без сети) → бандл → подпись → Release
```

Единый источник истины по образам — `images.yaml`. В `compose/docker-compose.yml` нет ни одного литерала образа: каждый `image:` — переменная `<ИМЯ>_IMAGE`, которую `scripts/render_env_images.py` генерирует из манифеста (режимы `digest` — онлайн, `bundle` — офлайн-бандл, `registry` — внутренний registry контура). Без `.env.images` compose намеренно не запускается.

## Три пути деплоя

| Путь | Когда | Каталог |
|---|---|---|
| **docker compose** (рекомендуется для одного сервера) | Один хост, systemd есть, самый короткий путь от нуля до работающего стенда | `compose/` |
| **Офлайн-бандл** | Закрытый контур без интернета | `scripts/build_offline_bundle.sh` → `install.sh` |
| **Helm / Kubernetes** | Уже есть кластер и вы хотите катить это в него как обычное приложение | `charts/rtk-crm/` |

Все описывают ОДНУ систему: Caddy, API, worker, миграции/сиды как одноразовые задачи, Keycloak, PostgreSQL, Redis, SeaweedFS, NTP, мок SMS-шлюза, веб-клиент (профиль `integrations` добавляет mock-lms/mock-cms, профиль `registry` — внутренний registry).

## Провижининг VM

Один раз на свежей машине, с правами root:

```bash
sudo bash scripts/provision_vm.sh
```

Идемпотентен. Проверяет наличие Docker + `docker compose` (сам не ставит), заводит системного пользователя `deploy` (группа `docker`; учтите — членство в `docker` равно root-доступу на хосте), каталоги `/srv/rtk-dev`, `/srv/rtk-demo`, `/srv/rtk-prod` (независимые compose-проекты `rtk-dev`/`rtk-demo`/`rtk-prod`), 2 ГБ swap.

Дальше — `docs/ghcr-setup.md`: classic PAT с правом **только** `read:packages`, вход в GHCR под пользователем `deploy`: `echo <PAT> | docker login ghcr.io -u <user> --password-stdin`. Без этого `docker compose pull` откажет — пакеты `ghcr.io/lct-testkit/*` приватные.

## Первый деплой на VM

Из-под пользователя `deploy`, для `rtk-demo` (для `dev`/`prod` — `RTK_ENV=dev|prod`):

```bash
git clone https://github.com/lct-testkit/deploy.git /srv/rtk-demo/deploy
cd /srv/rtk-demo/deploy
RTK_ENV=demo scripts/deploy.sh --init --host crm.example.local          # секреты + runtime/ в /srv/rtk-demo
RTK_ENV=dev  scripts/deploy.sh --init --port-offset 100                 # dev на соседних портах (8180/8543/…)
RTK_ENV=prod scripts/deploy.sh --init --host crm.example.local --profile prod
RTK_ENV=demo scripts/deploy.sh
```

`--init` (`scripts/gen_env.sh`) генерирует случайные секреты и, что важно, **согласованно** подставляет их в `.env`, в `runtime/keycloak/realm-crm.json` (client secret'ы) и в `runtime/seaweedfs/s3.json` (S3-ключи). Правка секретов только в `.env` приводила бы к рассинхрону: в демо-файлах они зашиты. `--port-offset` разводит порты нескольких окружений на одной машине. Демо-ПОЛЬЗОВАТЕЛИ realm остаются — до открытия доступа извне удалите их или смените пароли в консоли Keycloak.

`deploy.sh` тянет образы (`images.yaml` → `.env.images`), поднимает стек (`up --wait`), гоняет `scripts/smoke.sh`. Проверка вручную:

```bash
bash scripts/smoke.sh http://localhost:8080
```

## Автодеплой

`demo` и `dev` не обновляются руками — за это отвечает systemd-таймер:

```bash
sudo bash scripts/install_autodeploy.sh demo
```

Каждые 5 минут `scripts/deploy.sh` (от имени `deploy`): `git pull`, пересчёт `.env.images`; если ничего не изменилось — выход. Иначе: **бэкап** (`scripts/backup.sh`, хранится 7 последних), pull, `up -d --wait`, **smoke**; при любом сбое образы возвращаются на предыдущие (`.env.images.prev`), проваленные ссылки сохраняются в `.env.images.failed`. **prod автодеплоем не обновляется** — только осознанным запуском `RTK_ENV=prod scripts/deploy.sh`.

**Как новый образ доезжает досюда:** push в `backend`/`frontend` → их `ci.yml` (гейты → сборка → Trivy → push → подпись) шлёт `repository_dispatch` в этот репозиторий → `notify.yml` проверяет, что образ существует и digest совпадает, **поднимает стек с новым образом и гоняет smoke**, и только тогда коммитит tag/digest в `images.yaml` → таймер на VM подхватывает через `git pull`. SSH из CI на сервер нет и не нужно — только read-only PAT на самой VM.

```bash
systemctl status rtk-demo-autodeploy.timer
sudo systemctl start rtk-demo-autodeploy.service   # прогнать прямо сейчас
journalctl -u rtk-demo-autodeploy.service -f
```

## Обновление вручную и откат

```bash
RTK_ENV=dev scripts/deploy.sh              # обновить
RTK_ENV=demo scripts/deploy.sh rollback    # вернуть образы предыдущего успешного деплоя
```

**Важно:** миграции Alembic идут только вперёд. Откат образов не откатывает схему БД. Если новая ревизия успела применить необратимые миграции, восстановление — из бэкапа, снятого перед выкладкой (`/srv/rtk-<env>/backups/…`, путь печатает `deploy.sh`): сначала проверьте бэкап `scripts/restore_test.sh`, затем восстановите его в боевую БД (см. ниже).

Откат к произвольному коммиту `images.yaml`: `git -C <deploy> checkout <commit> -- images.yaml && RTK_ENV=… scripts/deploy.sh --no-pull`, потом `git checkout main -- images.yaml`, иначе следующий автодеплой перезапишет откат.

## Офлайн-установка (закрытый контур)

Каждый тег `vX.Y.Z` публикует в GitHub Releases бандл со ВСЕМИ образами, compose, скриптами и `SHA256SUMS`. Релиз выходит только если e2e зелёный, включая **установку бандла на машине без сети** (`.github/workflows/e2e.yml`).

На машине с доступом (или на любой, куда скачаете релиз):

```bash
sha256sum -c rtk-crm-offline-vX.Y.Z.tar.gz.sha256                 # целостность
cosign verify-blob rtk-crm-offline-vX.Y.Z.tar.gz.sha256 \
  --bundle rtk-crm-offline-vX.Y.Z.tar.gz.sha256.sigstore.json \
  --certificate-identity-regexp '^https://github.com/lct-testkit/deploy/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com   # происхождение (нужен cosign)
```

Перенос на изолированную машину (Docker и `docker compose` там уже стоят) и установка:

```bash
tar xzf rtk-crm-offline-vX.Y.Z.tar.gz && cd rtk-crm-offline-vX.Y.Z
bash install.sh --profile demo                                    # или: --profile prod --host crm.example.local
```

`install.sh`: `sha256sum -c SHA256SUMS` (при расхождении — стоп до загрузки образов) → `docker load` → генерация секретов → `up --wait --pull never` (docker **не ходит** в сеть) → smoke. Если архив нарезан на части (лимит вложения 2 ГиБ): `cat rtk-crm-offline-*.tar.gz.part-* > rtk-crm-offline.tar.gz`. Проверка подписи для air-gap: вместе с `cosign` понадобится доверенный корень Sigstore (`cosign initialize --mirror …`), либо сверяйте `.sha256` с копией, полученной по независимому каналу.

**Внутренний registry** (обновления без ручного переноса архивов): `bash install.sh --registry` поднимает `registry:2` на `localhost:5000` и заливает в него образы. На остальных машинах контура:

```bash
python3 scripts/render_env_images.py --mode registry --registry registry.local:5000 > /srv/rtk-demo/.env.images
```

Собрать бандл самостоятельно (нужен доступ к GHCR и `docker login`): `scripts/build_offline_bundle.sh [версия]`.

## Резервное копирование и восстановление

```bash
bash scripts/backup.sh --env-file /srv/rtk-demo/.env --images-env /srv/rtk-demo/.env.images \
                       --project rtk-demo --out /srv/rtk-demo/backups
```

Снимает: роли кластера (`pg_dumpall --roles-only` — без них права `crm_app` не восстановятся), базы `crm` и `keycloak`, том SeaweedFS, счётчики строк, `SHA256SUMS`. **Непроверенный бэкап не существует:**

```bash
bash scripts/restore_test.sh --backup /srv/rtk-demo/backups/<каталог> \
     --env-file /srv/rtk-demo/.env --images-env /srv/rtk-demo/.env.images
```

Поднимает чистый изолированный стенд (проект `rtk-restore-test`, порты 18080/…), восстанавливает базы, сверяет число строк (в каждой таблице не меньше, чем было до дампа), поднимает весь стек и гоняет smoke. Ночью то же делает `e2e.yml`. Целевые RTO 4 ч, RPO 15 мин (спека §6): дневной `pg_dump` даёт RPO сутки — для 15 минут добавьте WAL-архивирование (в этом репозитории не реализовано).

Для Kubernetes-пути — `kubectl exec` в под `postgres-0` тем же `pg_dump`/`pg_dumpall`, файлы SeaweedFS — снапшот PVC.

## Kubernetes / Helm

```bash
helm install rtk-crm charts/rtk-crm -n rtk-crm --create-namespace \
  --set secrets.postgresPassword=<реальный-пароль> \
  --set secrets.signatureServerSecret=<реальный-секрет>
```

Полный список значений — `charts/rtk-crm/values.yaml`. Обновление — `helm upgrade`, откат — `helm rollback`. **Статус:** чарт проходит `helm lint` и kubeconform, drift-проверку против `images.yaml`, но реальная установка в кластер в CI пока не гоняется; первая установка `helm install` может упереться в порядок хуков `migrate`/`seed` (`pre-install` выполняется раньше создания postgres) — используйте `helm upgrade --install` поверх уже созданной БД либо считайте Helm-путь экспериментальным. Основной поддерживаемый путь — compose. Известный долг чарта: у workload'ов нет `securityContext` (`runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop`) — Trivy misconfig даёт KSV-0118 и родственные; добавлять их нужно по одному образу с проверкой в кластере (postgres/keycloak/seaweedfs пишут в свои тома под конкретными UID), поэтому в CI misconfig-скан чарта не включён.

## Перед боевым контуром

Используйте `deploy.sh --init --profile prod` — он сам генерирует все секреты и не оставляет демо-значений в `.env`, `realm-crm.json`, `s3.json`; `deploy.sh` для `RTK_ENV=prod` отказывается стартовать с демо-секретами, а образ api при `APP_PROFILE=prod` не запустится с демо-значениями `SIGNATURE_SERVER_SECRET`, `KEYCLOAK_*_SECRET`, `S3_*`, `CRM_APP_PASSWORD`. Остаётся вручную: удалить/отключить демо-учётки в Keycloak, задать публичное имя сервера (`--host`), TLS-сертификат вместо `tls internal`.

## Мониторинг и логи

```bash
docker compose -p rtk-demo -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env \
  --env-file /srv/rtk-demo/.env.images logs -f api
```

`api`/`keycloak` отдают Prometheus-метрики на `/metrics` изнутри сети — сборщика в `compose/`/чарте нет (только эндпоинты). Ротация логов — `json-file` 10 МБ × 3.

## Устранение неполадок

| Симптом | Причина / что делать |
|---|---|
| `compose` пишет `required variable API_IMAGE is missing` | Не передан `.env.images`: `python3 scripts/render_env_images.py > .env.images` (или `deploy.sh`) |
| `docker compose pull` в `deploy.sh`: `unauthorized` | PAT на VM истёк или не логинились — `docs/ghcr-setup.md` п.1 |
| Таймер есть, но образы не обновляются | `journalctl -u rtk-demo-autodeploy.service` — конфликт `git pull` (не правьте файлы в чекауте руками) или `notify.yml` не прошёл (стек с новым образом не поднялся — смотрите его лог) |
| CI backend/frontend красный на шаге «Уведомить deploy» | `DEPLOY_DISPATCH_TOKEN` не задан (`docs/ghcr-setup.md` п.4) — образ уже в GHCR, но манифест не обновится |
| После деплоя откат образов, но схема БД «новее» кода | Миграции необратимы — восстановление из бэкапа перед выкладкой (см. выше) |
| Keycloak: вход не работает после смены секретов | Секреты меняли только в `.env`: используйте `gen_env.sh` (правит `.env`, realm и `s3.json` согласованно) |
| `up --wait` падает на seaweedfs на холодном старте | Проверьте `docker compose logs seaweedfs`; у healthcheck есть `start_period: 40s`, на очень медленных дисках увеличьте |
| Нужно сравнить, что реально задеплоено | `docker compose ... images` — сверить тег/digest с `images.yaml` |

Остальные симптомы (502 на `/api`, долгий старт Keycloak, сертификат `:8443`) — те же, что у локального стенда, см. «Устранение неполадок» в корневом README backend.
