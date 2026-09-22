# RUNBOOK — эксплуатация RTK School CRM

Как поднять систему на реальном сервере (не на машине разработчика — для этого есть `backend/docker-compose.yml`, см. корневой README) и поддерживать её: провижининг VM, первый деплой, автодеплой, откат, офлайн-установка, бэкап/восстановление, Kubernetes. Все команды — с целевого сервера (Ubuntu/Debian, systemd), если не сказано иное.

## Два пути деплоя

| Путь | Когда | Каталог |
|---|---|---|
| **docker compose** (рекомендуется для одного сервера) | Один хост, systemd есть, самый короткий путь от нуля до работающего стенда | `compose/` |
| **Helm / Kubernetes** | Уже есть кластер и вы хотите катить это в него как обычное приложение | `charts/rtk-crm/` |

Оба описывают ОДНУ и ту же систему (11 сервисов: Caddy, API, worker, миграции/сиды как одноразовые задачи, Keycloak, PostgreSQL, Redis, SeaweedFS, NTP, мок SMS-шлюза, веб-клиент) и оба тянут готовые образы из `ghcr.io/lct-testkit/*` — ничего не собирают на целевой машине. `images.yaml` в корне репозитория — единственный источник истины по тому, какой тег сейчас актуален; оба пути читают его (compose — через сгенерированный `.env.images`, Helm — через `values.yaml`, обновляемый тем же способом при релизе чарта).

Третий путь — **офлайн-поставка** (архив с образами, без сети в рантайме) — раздел «Офлайн-установка» ниже; использует тот же `compose/`.

## Провижининг VM

Один раз на свежей машине, с правами root:

```bash
sudo bash scripts/provision_vm.sh
```

Идемпотентен. Проверяет наличие Docker + `docker compose` (сам не ставит — установка Docker скриптом из интернета на root-правах через оператора этого репозитория осознанно не автоматизирована, слишком чувствительный шаг), заводит системного пользователя `deploy` (группа `docker`), каталоги `/srv/rtk-demo` и `/srv/rtk-dev` (два независимых compose-проекта — `rtk-demo` обновляется только автодеплоем и не трогается руками, `rtk-dev` можно ломать свободно для проверки), 2 ГБ swap.

Дальше — `docs/ghcr-setup.md`: создать GitHub PAT с правом **только** `read:packages`, `docker login ghcr.io` под пользователем `deploy` на VM. Без этого `docker compose pull` откажет — пакеты `ghcr.io/lct-testkit/*` приватные.

## Первый деплой на VM

Из-под пользователя `deploy`, для `rtk-demo` (для `rtk-dev` — то же самое с `RTK_ENV=dev` и в `/srv/rtk-dev`):

```bash
git clone https://github.com/lct-testkit/deploy.git /srv/rtk-demo/deploy
cd /srv/rtk-demo/deploy
cp compose/.env.example /srv/rtk-demo/.env
```

Откройте `/srv/rtk-demo/.env` и смените как минимум то, что помечено `# CHANGE ME` (пароли БД, секреты Keycloak, `SIGNATURE_SERVER_SECRET`, ключи S3) — раздел «Перед боевым контуром» ниже, полный список. Также выставьте `BASE_URL`/`KEYCLOAK_PUBLIC_URL`/`CRM_TLS_HOST` на реальное доменное имя сервера, если оно не `localhost`.

```bash
scripts/deploy.sh
```

Тянет образы (`images.yaml` → `.env.images`), поднимает стек. На чистой машине — минута-две, дольше всего стартует Keycloak. Проверка:

```bash
docker compose -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env --env-file /srv/rtk-demo/.env.images --project-directory /srv/rtk-demo ps
curl http://localhost:8080/health/ready
```

## Автодеплой

`rtk-demo` не обновляется руками (`git pull` + `docker compose up -d` каждый раз) — за это отвечает systemd-таймер:

```bash
sudo bash scripts/install_autodeploy.sh demo
```

Ставит `rtk-demo-autodeploy.timer`, каждые 5 минут запускающий `scripts/deploy.sh` от имени `deploy`: `git pull` в самом `deploy`-репозитории (подтягивает и `compose/docker-compose.yml`, и свежий `images.yaml`, если тот успел обновиться), пересчитывает теги образов, `docker compose pull && up -d`. Идемпотентен — если ничего не изменилось, шаг `up -d` не трогает контейнеры.

**Как новый образ доезжает досюда:** push в `backend`/`frontend` → их `build.yml` собирает и пушит образ в GHCR, затем шлёт `repository_dispatch` в этот репозиторий → `.github/workflows/notify.yml` проставляет новый tag/digest в `images.yaml` и коммитит → в течение 5 минут таймер на VM подхватывает через `git pull`. Никакого SSH из CI на сервер нет и не нужно — только read-only PAT на самой VM (раздел «Провижининг VM»). Полный цикл push → на проде — обычно 3–8 минут (время сборки образа + до 5 минут ожидания таймера).

Проверить/прогнать вручную:

```bash
systemctl status rtk-demo-autodeploy.timer
sudo systemctl start rtk-demo-autodeploy.service   # прогнать прямо сейчас, не дожидаясь таймера
journalctl -u rtk-demo-autodeploy.service -f
```

## Обновление вручную и откат

Вне автодеплоя (например, на `rtk-dev`, где таймер не ставится):

```bash
cd /srv/rtk-dev/deploy && RTK_ENV=dev scripts/deploy.sh
```

**Откат** — `images.yaml` версионируется в git, поэтому предыдущий известный рабочий тег всегда достижим:

```bash
git -C /srv/rtk-demo/deploy log --oneline -- images.yaml   # найти коммит ДО проблемного
git -C /srv/rtk-demo/deploy checkout <commit> -- images.yaml
RTK_ENV=demo /srv/rtk-demo/deploy/scripts/deploy.sh
git -C /srv/rtk-demo/deploy checkout main -- images.yaml   # вернуть HEAD, иначе следующий автодеплой перезапишет откат
```

Учтите: откат образа `api` не откатывает применённые миграции БД — Alembic только накатывает вперёд (см. «Ранбук» в корневом README, раздел «Обновление» — то же ограничение).

## Kubernetes / Helm

```bash
helm install rtk-crm charts/rtk-crm -n rtk-crm --create-namespace \
  --set secrets.postgresPassword=<реальный-пароль> \
  --set secrets.signatureServerSecret=<реальный-секрет>
  # остальные секреты — см. values.yaml, все с дефолтами для демо и комментарием "CHANGE ME"
```

Полный список переопределяемых значений — `charts/rtk-crm/values.yaml` (образы/теги, реплики, ресурсы, размеры PVC, `ingress.enabled`). Обновление — `helm upgrade rtk-crm charts/rtk-crm -n rtk-crm -f <ваш values-оverride>`; откат — `helm rollback rtk-crm <ревизия>`. `migrate`/`seed` идут Helm-хуками `pre-install,pre-upgrade` — следят за ними `kubectl get jobs -n rtk-crm`. Автодеплоя (push → новый образ → сам себя обновил) для Helm-пути в этом репозитории нет — актуальный тег в `values.yaml` обновляет тот же `notify.yml`, но накатить `helm upgrade` после этого — ручной шаг (или заведите свой ArgoCD/Flux поверх — чарт для этого готов, GitOps-контроллер — решение оператора кластера, не этого репозитория).

## Офлайн-установка

Для контура без доступа к GHCR/интернету в рантайме (rtk_requiriments.md — сервис рассчитан на закрытый контур). Каждый тег `vX.Y.Z` этого репозитория публикует архив со всеми образами в GitHub Releases:

```bash
curl -LO https://github.com/lct-testkit/deploy/releases/download/vX.Y.Z/rtk-crm-offline-vX.Y.Z.tar.gz
tar xzf rtk-crm-offline-*.tar.gz && cd rtk-crm-offline-*
bash install.sh
```

`install.sh` делает `docker load` (образы уже внутри архива, сеть не нужна), копирует `.env` из примера, поднимает стек. Docker + `docker compose`-плагин на целевой машине нужно поставить заранее (единственный шаг, где нужна сеть — до переноса на изолированную машину). Собрать бандл самостоятельно (например, промежуточную сборку без ожидания релиза):

```bash
scripts/build_offline_bundle.sh
```

## Резервное копирование и восстановление

Тот же набор данных, что в «Ранбук» корневого README (PostgreSQL — базы `crm` и `keycloak`, файлы SeaweedFS), только пути другие — `/srv/rtk-demo` вместо `backend/`:

```bash
docker compose -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env --project-directory /srv/rtk-demo \
  exec -T postgres pg_dump -U crm -Fc crm > crm.dump
```

Для Kubernetes-пути — `kubectl exec` в под `postgres-0` тем же `pg_dump`, файлы SeaweedFS — снапшот PVC средствами вашего кластера (CSI-снапшоты, если провайдер их поддерживает) или тот же `tar` через временный под с примонтированным PVC.

## Перед боевым контуром

Все значения по умолчанию (`compose/.env.example`, `values.yaml`) — демонстрационные, встречаются в открытом репозитории. Обязательно сменить: пароли PostgreSQL (`POSTGRES_PASSWORD`, `CRM_APP_PASSWORD`), пароль консоли Keycloak (`KEYCLOAK_ADMIN_PASSWORD`), секреты клиентов OIDC (`KEYCLOAK_CLIENT_SECRET`, `KEYCLOAK_ADMIN_CLIENT_SECRET`), `SIGNATURE_SERVER_SECRET` (HMAC-метка целостности ПЭП), ключи SeaweedFS S3 (`S3_ACCESS_KEY`/`S3_SECRET_KEY`), пароли демо-учёток Keycloak (или удалить их из realm — `APP_MODE=prod` у образа `web` и так прячет форму выбора демо-роли, но сами учётки в Keycloak при этом остаются активны, если их не отключить отдельно). Подробное обоснование каждой переменной — `backend/README.md` в основном репозитории.

## Мониторинг и логи

```bash
docker compose -f compose/docker-compose.yml --env-file /srv/rtk-demo/.env --project-directory /srv/rtk-demo logs -f api
```

`api`/`keycloak` отдают Prometheus-метрики на `/metrics` изнутри сети (Caddy отдаёт `404` наружу сознательно) — сборщика (Prometheus/Grafana) в `compose/`/чарте нет, только сами эндпоинты; подключение реального стека мониторинга — за пределами этого репозитория. Ротация логов на VM — `json-file` с ограничением (см. `compose/docker-compose.yml`); в Kubernetes ротацию логов контейнеров делает сам kubelet.

## Устранение неполадок

| Симптом | Причина / что делать |
|---|---|
| `docker compose pull` в `deploy.sh`: `unauthorized` | PAT на VM истёк или не логинились — `docs/ghcr-setup.md` п.1 |
| Таймер есть, но образы не обновляются | `journalctl -u rtk-demo-autodeploy.service` — скорее всего `git pull` в `/srv/rtk-demo/deploy` конфликтует (кто-то правил файлы в чекауте руками — не делайте так, это авто-обновляемый чекаут) |
| `render_env_images.py` предупреждает `tag пуст` | `images.yaml` ещё не обновлён свежей сборкой — CI backend/frontend не запускался или `DEPLOY_DISPATCH_TOKEN` не настроен (`docs/ghcr-setup.md` п.3) |
| `helm lint`/`helm template` не проходит после правки чарта | `helm template charts/rtk-crm \| kubeconform -strict` локально, тот же шаг гоняет `validate.yml` |
| Нужно сравнить, что сейчас реально задеплоено | `docker compose ... images` (compose) или `kubectl get pods -n rtk-crm -o jsonpath='{.items[*].spec.containers[*].image}'` (Helm) — сверить тег с `images.yaml` |

Остальные симптомы (502 на `/api`, долгий старт Keycloak, сертификат `:8443`) — те же, что у локального стенда, см. «Устранение неполадок» в корневом README — deploy-специфичного там нет, только адреса/пути другие.
