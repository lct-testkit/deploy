# Открытые задачи deploy

Список того, что не сделано или требует решения. Всё выполненное убрано: установщик с выбором окружения, адреса и TLS, моковые данные, шрифты, `set_host.sh`, админ Keycloak 25, отказ от предвыделения места в SeaweedFS и синхронизация Caddyfile с backend вошли в релиз `v0.3.1` и проверены на сервере `lct.velikoss.ru` (26.09.2026: `smoke.sh` зелёный, миграции до 0020, диск 13%). Разделы упорядочены по важности.

## 1. Переменные бэкенда

`x-api-env` в `compose/docker-compose.yml` совпадает с бэкендом (42 имени, сверяет `check_drift.py --backend-dir`), `gen_env.sh` создаёт `AUDIT_HMAC_KEY` и `SETTINGS_ENCRYPTION_KEY`, почта описана в `RUNBOOK.md`. Helm-чарт получил те же переменные (`charts/rtk-crm/templates/_helpers.tpl` — `AUDIT_HMAC_KEY`/`SETTINGS_ENCRYPTION_KEY`/`SMTP_PASSWORD` через Secret, остальное через `values.yaml`; `helm lint` зелёный). Осталось:

- [x] На уже развёрнутых стендах добавить ключи в `.env` и пересоздать `api` и `worker` — снято: с v0.3.2 `lct` переустанавливался с нуля несколько раз (v0.4.0, v0.5.0/v0.5.1), каждый раз из бандла, где `gen_env.sh` уже создаёт эти ключи; стенда старше v0.3.2 не осталось.
- [x] `check_drift.py` сверял список x-api-env только с `compose/docker-compose.yml`, не с чартом — снято: `check_api_env` в `scripts/check_drift.py` теперь дополнительно сверяет множество имён с `define "rtk-crm.apiEnv"` в `charts/rtk-crm/templates/_helpers.tpl` (без учёта `POSTGRES_PASSWORD` — она там только для сборки `KC_DATABASE_URL`, не настройка приложения).

## 2. Безопасность demo-режима и prod

- [ ] Экран входа и `/config.json` в demo публикуют демо-логины и секрет клиента `crm-bff`: любой посетитель `lct.velikoss.ru` входит администратором. Установщик предупреждает, но не запрещает. Решить: закрыть демо-стенд по IP или basic-auth в Caddy, либо перевести боевой домен на `--profile prod`.
- [ ] Демо-пользователи realm остаются и в `prod` (`gen_env.sh` только предупреждает): удалять или менять пароли при `--profile prod`.
- [ ] После `set_host.sh` старые `redirect_uris` и `web_origins` клиента `crm-bff` остаются допустимыми: убирать адреса прежнего хоста.
- [x] Процедура сброса пароля администратора Keycloak, если `.env` менялся после первого старта — снято: описана в `RUNBOOK.md`, «Администратор Keycloak» («Пароль администратора разошёлся с `.env`»). `kc.sh bootstrap-admin user` в закреплённой версии `25.0` не существует (появилась в Keycloak 26+, проверено на образе) — процедура через прямое удаление пользователя `admin` из БД `keycloak`.
- [ ] Флаги установщика, которых пока нет: `--email` (уведомления Let's Encrypt), `--yes-i-know-demo` (подтверждение demo на публичном адресе).

## 3. Проверить путь ACME и режимы `set_host.sh`

- [ ] Свободная VM с DNS-записью: `install.sh --profile demo --host <домен> --tls acme` «с нуля», убедиться, что сертификат выпустился, `smoke.sh https://<домен>` зелёный, http→https работает (на `lct` установка прошла, но поверх снесённого стенда).
- [ ] `set_host.sh` в публичных режимах (`off` → `acme`, `acme` → `internal`) не проверялся.

## 4. CI и тесты

- [ ] `e2e.yml`, job `offline-bundle`: добавить прогон `--tls internal` (порт 443 на раннере доступен).
- [ ] Автотесты на `gen_env.sh` и `lib_host.sh` (например bats): режим `off` совпадает с прежним `.env`, валидный JSON realm, ошибки сочетаний параметров.
- [ ] Вызывать `scripts/sync_seed.sh --frontend-dir ../frontend --check` в `validate.yml` (нужен checkout `frontend` с токеном).
- [ ] `deploy.sh --seed`: моковые данные VM-окружения пока заливаются вручную (`seed_demo.sh --env-file … --project …`, см. `RUNBOOK.md`); `e2e_stack.sh` сиды не запускает.

## 5. Релиз

- [ ] Шрифты Rostelecom Basis не попадают в релизный бандл (лицензионные, не в git): решить, откуда CI берёт файлы (приватный релиз-ассет или секрет-архив), и вызывать `build_offline_bundle.sh … --fonts <каталог>`. Пока шрифты передаются при установке (`--fonts`) или кладутся в `compose/fonts/`.
- [x] Удалить неудачный тег `v0.3.0` (релиз упал на сидах, исправлено в `v0.3.1`) — снято: тег удалён локально и на origin (`git push origin :refs/tags/v0.3.0`).

## 6. Данные демо, которых нет после сидов

- [ ] Дашборд «Обзор воронки» (`dashboards`, `dashboard_widgets`): создаёт сценарий `b-reports.mjs` через браузер (Playwright).
- [ ] Соглашения ЭДО (`edm_agreements`): `lead-edm.mjs`, тоже через браузер.
- [ ] История импортов (`import_jobs`, `import_presets`): `b-imports.mjs`, нужен xlsx на 240 строк.
- [ ] Пять сделок (`D-2026-000008/12/18/19/20`) стоят на переходе «Передать материалы в LMS»: без `LMS_BASE_URL` он недоступен. Для demo можно включать профиль `integrations` (mock-lms) и задавать `LMS_BASE_URL`.

Для первых трёх нужны API-версии в `frontend/tools` (браузер в контейнере не работает), затем `sync_seed.sh` подхватит их в `seed/`.

## 7. Эксплуатация

- [ ] Алерт на заполнение диска: инцидент `No space left on device` проявился как 500 в API и падение сидов, а не как понятная ошибка. Метрики приложения теперь есть (профиль compose `monitoring` / `values.monitoring.enabled`: Prometheus + Grafana, см. RUNBOOK.md, «Мониторинг и логи») — но это метрики backend, не диска/хоста: node_exporter/cAdvisor и алертинг (Alertmanager или Grafana alerting) по-прежнему не заведены, для конкретно этого инцидента толку от новой Grafana пока нет.
- [x] Метрики backend, объявленные в `app/core/metrics.py`, но нигде не обновлявшиеся (`crm_sla_violations_total`, `crm_sla_breaching_deals`, `crm_reports_in_progress`, `crm_background_task_duration_seconds`, `crm_import_duration_seconds`/`crm_import_rows_total`, `crm_cache_requests_total`), подключены в backend; метрики воркера собирает отдельный job `worker` (порт 9101) в `prometheus.yml`, панели «SLA и отчёты» и новые «Длительность фоновых задач», «Кэш графа воронки», «Импорт» в `business-ops.json` показывают данные после выкладки образа backend с этими изменениями (до неё `up{job="worker"}` = 0 — воркер прежнего образа `/metrics` не отдаёт). Остаток: gauge `crm_sla_breaching_deals` выставляет та реплика воркера, на которой прошёл cron-скан, у остальных он устаревает — дашборд берёт `max` по репликам, при нескольких репликах воркера возможен устаревший максимум.
- [ ] RPO 15 минут недостижим без WAL-архивирования: суточный дамп даёт сутки.
- [ ] Helm-путь экспериментальный: реальная установка в CI не гоняется, у workload'ов нет `securityContext` (кроме `ntp` — capabilities, и `prometheus`/`grafana` — `fsGroup` для PVC, см. RUNBOOK.md). Режимов TLS, шрифтов и сидов в чарте нет (Kubernetes использует свой ingress) — осознанное ограничение.
- [ ] На сервере `lct` проверить шрифты в `compose/fonts/` (в репозитории их быть не может).
- [ ] Репозиторий: применить ruleset к `.github` и включить `require_code_owner_review` (см. `REPO-SETTINGS.md`) — ветка бота `bot/update-images-35271171079` уже удалена.
