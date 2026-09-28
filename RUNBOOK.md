# RUNBOOK — эксплуатация RTK School CRM

Как поднять систему на реальном сервере (не на машине разработчика — для этого есть `backend/docker-compose.yml`, см. [README продукта](https://github.com/lct-testkit/.github#readme)) и поддерживать её: конвейер поставки, провижининг VM, первый деплой, автодеплой, откат, офлайн-установка, бэкап/восстановление, Kubernetes. Все команды — с целевого сервера (Ubuntu/Debian, systemd), если не сказано иное.

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

Моковые данные для демо-окружения VM (только `RTK_ENV=demo`/`dev`, в prod отказ) заливаются после первого деплоя:

```bash
bash scripts/seed_demo.sh --env-file /srv/rtk-demo/.env --images-env /srv/rtk-demo/.env.images --project rtk-demo
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
bash install.sh                                                   # в терминале: спросит окружение, адрес и моковые данные
bash install.sh --profile demo --host crm.example.local --seed    # демо-стенд с моковыми данными, без вопросов
bash install.sh --profile demo --no-seed                          # демо-стенд, чистая система
bash install.sh --profile prod --host crm.example.local           # боевое окружение
```

**Что выбирается при установке** (в терминале — вопросами, иначе флагами; без терминала и без флагов берутся значения по умолчанию):

| Выбор | Флаг | Варианты и последствия |
|---|---|---|
| Окружение | `--profile` (синоним `--env`) | `demo` (по умолчанию): демо-учётки на экране входа, `APP_MODE=demo`, можно залить моковые данные. `prod`: случайные секреты, экран входа без демо-учёток, моковые данные недоступны; адрес (`--host`) обязателен |
| Адрес | `--host` | Имя или IP, по которому открывают систему: попадает в `BASE_URL`, Keycloak, presigned-ссылки S3 и имя TLS-сайта. Без него — `localhost` |
| TLS | `--tls acme\|internal\|off` | Как отдаётся система, подробнее в разделе «Домен и TLS» ниже. По умолчанию из адреса: домен → `acme`, IP и внутренние имена (`.local`, `.lan`, без точки) → `internal`, `localhost` → `off` |
| Шрифты | `--fonts <каталог>` | Каталог с `*.woff` Rostelecom Basis. Не нужен, если шрифты вошли в бандл (`compose/fonts`) |
| Моковые данные | `--seed` / `--no-seed` | Только для demo, там включено по умолчанию. Заливает справочники (направления, причины отказа, **праздники 2026**, пользовательские поля), реестр ЕГРЮЛ, SLA, 14 организаций, контакты, ~39 сделок по статусам воронки с комментариями и задачами, сценарии «Удаление ПДн» и «Согласования» |
| Порты | `--port-offset N` | Сдвиг 8080/8443/8333/5433 на N: несколько стендов на одной машине (`COMPOSE_PROJECT_NAME=<имя>` разводит проекты) |

Перед установкой показывается сводка (окружение, адрес, моковые данные), в терминале — с подтверждением. Если `compose/.env` уже есть (повторный запуск), окружение и адрес берутся из него, а смена окружения запрашивает новую установку: секреты и пароли БД в томах привязаны к прежнему `.env`.

**Моковые данные.** Их наполняют три скрипта из `seed/` (копии из репозитория frontend, `scripts/sync_seed.sh --check` сверяет их с оригиналами), исполняются одноразовым контейнером `seed-demo` (`node:24-alpine`, образ лежит в бандле, сеть не нужна) внутри сети стека под демо-учётками. Идемпотентно: повторный запуск ничего не дублирует. Залить позже или повторить после сбоя: `bash scripts/seed_demo.sh` (`--only catalogs,demo,erasure` — отдельные этапы). Ошибка сидов не откатывает установку, но `install.sh` завершится с кодом 1. В `prod` сиды не работают и отказываются запускаться: вход по Bearer там ограничен ролью `INTEGRATION`, а `/config.json` не отдаёт секрет клиента.

### Домен и TLS

| Режим | Кому | Что происходит |
|---|---|---|
| `acme` | публичный домен | HTTPS на 443, сертификат Let's Encrypt выпускается автоматически при первом обращении (HTTP-01 через порт 80), http перенаправляется на https. Нужны A-запись домена на этот сервер и порты 80/443 из интернета |
| `internal` | закрытый контур, IP, внутренние имена | HTTPS на 443, самоподписанный сертификат Caddy. Корневой сертификат для клиентов: `docker compose … cp caddy:/data/caddy/pki/authorities/local/root.crt .` (команду печатает установщик) |
| `off` | локально, тест, несколько стендов на одной VM | Как раньше: `http://ХОСТ:8080` и `https://ХОСТ:8443` (самоподписанный); порты сдвигает `--port-offset` |

В `acme` и `internal` порты 80, 443 и 8333 (S3-прокси, presigned-ссылки) фиксированы, `--port-offset` недопустим, такой стенд на машине один. Plain-http `:8080` публикуется только на loopback: **Docker публикует порты в обход ufw**, поэтому всё, что не должно быть видно снаружи, привязывается к `127.0.0.1`, а не полагается на файрвол. Сертификаты лежат в томе `caddy_data`: не удаляйте его без нужды (`down -v`), у Let's Encrypt есть лимит выпусков на домен.

Перед установкой в публичном режиме (до `docker load`) установщик проверяет: свободны ли порты 80/443/8333, резолвится ли имя и указывает ли оно на внешний адрес сервера (для `acme`; отключить: `--skip-dns-check`), доступен ли Let's Encrypt, пропускает ли ufw нужные порты (напечатает `ufw allow …`, с `--open-firewall` откроет сам). Если что-то не так, установка останавливается без изменений.

**Смена адреса или режима у установленного стенда** (без переустановки, секреты и данные остаются):

```bash
bash scripts/set_host.sh --host crm.example.ru --tls acme      # то же: bash install.sh --reconfigure --host … --tls …
```

Realm Keycloak импортируется один раз, при создании БД, поэтому правка файла у работающего стенда ничего не меняет и вход на новом домене падает с `invalid_redirect_uri`. Скрипт делает три вещи: переписывает `.env` (и копию `.env.bak-<время>`), прописывает адреса клиента `crm-bff` прямо в БД Keycloak и пересоздаёт сервисы с перезапуском Keycloak. Старые адреса в списке допустимых остаются, при необходимости уберите их в консоли Keycloak. Для окружений `deploy.sh`: `--env-file /srv/rtk-<env>/.env --images-env /srv/rtk-<env>/.env.images --project rtk-<env>`.

### Шрифты Rostelecom Basis

Шрифты лицензионные и не входят ни в git, ни в образ `web` (`frontend/static/fonts` в `.gitignore`, файлы выдаёт заказчик). Без них интерфейс работает на запасной гарнитуре, а `smoke.sh` печатает предупреждение (не ошибку). Варианты: при сборке бандла `scripts/build_offline_bundle.sh <версия> --fonts ../frontend/static/fonts` (файлы попадут в `compose/fonts` и `SHA256SUMS`), при установке `install.sh --fonts <каталог>` (копируются в `runtime/fonts`), на работающем стенде достаточно положить `*.woff` в `compose/fonts/`: каталог смонтирован в Caddy, перезапуск не нужен. Релизный бандл из CI собирается без шрифтов: их нужно передавать установкой или отдельной сборкой.

### Администратор Keycloak

Пароль администратора консоли Keycloak (`admin`, пароль в `compose/.env`: `KEYCLOAK_ADMIN_PASSWORD`) работает, если в compose заданы `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD`. В Keycloak 25.x переменные `KC_BOOTSTRAP_ADMIN_*` игнорируются (появились в 26), и на стендах, поднятых со старым compose, в master realm нет ни одного пользователя. Исправление вступает в силу при пересоздании контейнера keycloak: обновите `docker-compose.yml` и выполните `docker compose … up -d keycloak`. Администратор создаётся при старте, только если master realm пуст (проверено: 0 пользователей до обновления, 1 после, вход в консоль проходит).

**Доступ к консоли администратора Keycloak.** Caddy отдаёт `/auth/admin/*` и `/auth/realms/master/*` только из закрытых сетей (`private_ranges`: localhost, docker, VPN): с публичного адреса консоль отвечает 404, вход под `admin` снаружи невозможен. Открыть консоль на сервере — через ssh-туннель (`ssh -L 8080:localhost:8080 сервер`, затем `http://localhost:8080/auth/admin/`) или расширить список: `ADMIN_CONSOLE_ALLOW="10.0.0.0/8 203.0.113.7"` в `compose/.env` и `docker compose up -d caddy`. Обычный вход пользователей (`/auth/realms/crm/...`) закрытие не затрагивает.

### Ключи аудита и почта

`gen_env.sh` при первой установке создаёт два случайных ключа и записывает их в `.env`: `AUDIT_HMAC_KEY` (HMAC цепочки аудита, хэш v3; без него цепочку можно пересчитать целиком тому, у кого есть доступ к БД) и `SETTINGS_ENCRYPTION_KEY` (ключ Fernet, которым шифруются секретные системные настройки). Оба ключа нужно сохранить вместе с бэкапом БД: потеря `SETTINGS_ENCRYPTION_KEY` делает зашифрованные настройки нечитаемыми, а смена `AUDIT_HMAC_KEY` не даёт проверить записи, подписанные прежним ключом. Стенд, поставленный раньше, ключей не имеет (аудит остаётся на хэше v2): добавьте значения в `.env` вручную и перезапустите `api` и `worker`.

Почта (ссылки подписантам, email-уведомления) включается переменными `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_STARTTLS` в `.env`. Пока `SMTP_HOST` пуст, письма остаются в очереди, а вход по приглашению в закрытом контуре без почты Keycloak не работает.

### Диск и SeaweedFS

Без флага `-master.volumePreallocate=false` SeaweedFS резервировал на диске весь `volumeSizeLimitMB` при создании тома (1 ГБ на том, по 7 томов на бакет): пустой стенд занимал 20–36 ГБ, а два-три стенда на VM в 69 ГБ приводили к `No space left on device` и 500 в API. Флаг добавлен в compose и Helm-чарт, место теперь выделяется по мере роста данных (проверено: 35 томов занимают 308 КБ вместо 36 ГБ). **На уже работающих стендах** пересоздание контейнера освободит место не сразу: уже созданные `.dat` остаются предвыделенными. Для демо-стенда проще пересоздать том SeaweedFS (`docker compose down`, `docker volume rm <проект>_seaweed_data`, `up -d`, затем `bash scripts/seed_demo.sh`; загруженные файлы пропадут), для боевого нужен перенос данных.

**Осторожно с demo на публичном адресе:** экран входа и `/config.json` показывают демо-логины и секрет клиента Keycloak. Не открывайте такой стенд в интернет; для боевого использования ставьте `--profile prod`.

`install.sh`: параметры → `sha256sum -c SHA256SUMS` (при расхождении — стоп до загрузки образов) → подпись архива (cosign, см. ниже) → `docker load` → генерация секретов → `up --wait --pull never` (docker **не ходит** в сеть) → smoke → моковые данные. Если архив нарезан на части (лимит вложения 2 ГиБ): `cat rtk-crm-offline-*.tar.gz.part-* > rtk-crm-offline.tar.gz`. Проверка подписи для air-gap: вместе с `cosign` понадобится доверенный корень Sigstore (`cosign initialize --mirror …`), либо сверяйте `.sha256` с копией, полученной по независимому каналу.

`install.sh` сам пытается проверить подпись архива, а не только `SHA256SUMS` бандла: если каталог распаковали там же, где скачали (`.tar.gz`/`.sha256`/`.sigstore.json` лежат рядом, уровнем выше распакованного каталога — обычный сценарий из этого раздела) и `cosign` установлен, шаг «1/6» сверяет её автоматически и **останавливает установку**, если подпись не сошлась. Если файлы не найдены рядом (перенесли только распакованный каталог) — шаг молча переходит к ручной сверке выше, установка не блокируется.

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

Полный список значений — `charts/rtk-crm/values.yaml`. Обновление — `helm upgrade`, откат — `helm rollback`. **Статус:** чарт проходит `helm lint` и kubeconform, drift-проверку против `images.yaml`, но реальная установка в кластер в CI пока не гоняется; первая установка `helm install` может упереться в порядок хуков `migrate`/`seed` (`pre-install` выполняется раньше создания postgres) — используйте `helm upgrade --install` поверх уже созданной БД либо считайте Helm-путь экспериментальным. Основной поддерживаемый путь — compose. Известный долг чарта: у workload'ов нет `securityContext` (`runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop`) — Trivy misconfig даёт KSV-0118 и родственные; добавлять их нужно по одному образу с проверкой в кластере (postgres/keycloak/seaweedfs пишут в свои тома под конкретными UID), поэтому в CI misconfig-скан чарта не включён. Исключение — `prometheus`/`grafana` (`values.monitoring.enabled`): им заведён минимальный `securityContext.fsGroup` (65534/472, те же UID, что у официальных образов и их собственных Helm-чартов) — без него оба пишут на PVC под непривилегированным пользователем и не стартуют на свежем томе (в docker-compose эту проблему решает сам Docker, копируя владельца каталога из образа при первом использовании именованного volume — на PVC такого нет).

## Перед боевым контуром

Используйте `deploy.sh --init --profile prod` — он сам генерирует все секреты и не оставляет демо-значений в `.env`, `realm-crm.json`, `s3.json`; `deploy.sh` для `RTK_ENV=prod` отказывается стартовать с демо-секретами, а образ api при `APP_PROFILE=prod` не запустится с демо-значениями `SIGNATURE_SERVER_SECRET`, `KEYCLOAK_*_SECRET`, `S3_*`, `CRM_APP_PASSWORD`. Остаётся вручную: удалить/отключить демо-учётки в Keycloak. Публичное имя и TLS задаются при установке (`--host`, `--tls acme`, см. «Домен и TLS»).

## Мониторинг и логи

```bash
docker compose -p rtk-demo -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env \
  --env-file /srv/rtk-demo/.env.images logs -f api
```

`api`/`keycloak` отдают Prometheus-метрики (`/metrics`, `/auth/metrics`) изнутри сети; сборщик — опциональный профиль compose `monitoring` (`values.monitoring.enabled` в чарте), по умолчанию не поднимается:

```bash
docker compose -p rtk-demo -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env \
  --env-file /srv/rtk-demo/.env.images --profile monitoring up -d
```

Поднимает Prometheus (TSDB на volume `prometheus_data`, история — `PROMETHEUS_RETENTION`, по умолчанию 15 дней) и Grafana с двумя дашбордами, провижининг которых — файлы в git (`compose/grafana/`, идентичны `charts/rtk-crm/files/grafana/` — сверяет `check_drift.py`), а не клики в UI: дашборд «API — здоровье и производительность» (запросы/с, доля ошибок, p50/p95/p99 с порогом 300 мс) и «бизнес-метрики и эксплуатация» (очередь, фоновые задачи, аудит, доступность зависимостей). Grafana — на `/grafana` за Caddy (`GF_SERVER_ROOT_URL`/`GF_SERVER_SERVE_FROM_SUB_PATH`, вход — `GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD` из `.env`, `gen_env.sh` генерирует пароль случайным). Таргет Prometheus `api:8000` — одно имя, не список реплик: подробности и разбор компромисса — комментарий в `compose/prometheus/prometheus.yml`. Через `bundle_install.sh`/`install.sh` — флаг `--monitoring`. Ротация логов — `json-file` 10 МБ × 3.

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

Остальные симптомы (502 на `/api`, долгий старт Keycloak, сертификат `:8443`) — те же, что у локального стенда, см. раздел «Устранение неполадок» в [README продукта](https://github.com/lct-testkit/.github#readme).
