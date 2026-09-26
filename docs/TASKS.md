# Открытые задачи deploy

Список того, что не сделано или требует решения. Всё выполненное убрано: установщик с выбором окружения, адреса и TLS, моковые данные, шрифты, `set_host.sh`, админ Keycloak 25, отказ от предвыделения места в SeaweedFS и синхронизация Caddyfile с backend вошли в релиз `v0.3.1` и проверены на сервере `lct.velikoss.ru` (26.09.2026: `smoke.sh` зелёный, миграции до 0020, диск 13%). Разделы упорядочены по важности.

## 1. Пробросить переменные бэкенда в контейнеры api

`x-api-env` в `compose/docker-compose.yml` знает 31 переменную, у бэкенда их 42. Не пробрасываются `AUDIT_HMAC_KEY`, `SETTINGS_ENCRYPTION_KEY`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_STARTTLS`, `SIGNATURE_EXPOSE_DEBUG_OTP`, `ALLOWED_FILE_EXTENSIONS`, `BITRIX_SOURCE_ID`. Пока список не расширен, на развёрнутых стендах HMAC аудита (хэш v3), почта подписантам и шифрование системных настроек выключены.

- [ ] Добавить переменные в `x-api-env` compose и в шаблоны Helm-чарта.
- [ ] Генерировать `AUDIT_HMAC_KEY` и `SETTINGS_ENCRYPTION_KEY` в `scripts/gen_env.sh` (в prod без них не запускаться), описать включение SMTP в `RUNBOOK.md`.
- [ ] Научить `check_drift.py` сверять список переменных `x-api-env` с бэкендом.

## 2. Безопасность demo-режима и prod

- [ ] Экран входа и `/config.json` в demo публикуют демо-логины и секрет клиента `crm-bff`: любой посетитель `lct.velikoss.ru` входит администратором. Установщик предупреждает, но не запрещает. Решить: закрыть демо-стенд по IP или basic-auth в Caddy, либо перевести боевой домен на `--profile prod`.
- [ ] Демо-пользователи realm остаются и в `prod` (`gen_env.sh` только предупреждает): удалять или менять пароли при `--profile prod`.
- [ ] После `set_host.sh` старые `redirect_uris` и `web_origins` клиента `crm-bff` остаются допустимыми: убирать адреса прежнего хоста.
- [ ] Процедура сброса пароля администратора Keycloak, если `.env` менялся после первого старта (`kc.sh bootstrap-admin user`), в `RUNBOOK.md`.
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
- [ ] Удалить неудачный тег `v0.3.0` (релиз упал на сидах, исправлено в `v0.3.1`).

## 6. Данные демо, которых нет после сидов

- [ ] Дашборд «Обзор воронки» (`dashboards`, `dashboard_widgets`): создаёт сценарий `b-reports.mjs` через браузер (Playwright).
- [ ] Соглашения ЭДО (`edm_agreements`): `lead-edm.mjs`, тоже через браузер.
- [ ] История импортов (`import_jobs`, `import_presets`): `b-imports.mjs`, нужен xlsx на 240 строк.
- [ ] Пять сделок (`D-2026-000008/12/18/19/20`) стоят на переходе «Передать материалы в LMS»: без `LMS_BASE_URL` он недоступен. Для demo можно включать профиль `integrations` (mock-lms) и задавать `LMS_BASE_URL`.

Для первых трёх нужны API-версии в `frontend/tools` (браузер в контейнере не работает), затем `sync_seed.sh` подхватит их в `seed/`.

## 7. Эксплуатация

- [ ] Алерт на заполнение диска: инцидент `No space left on device` проявился как 500 в API и падение сидов, а не как понятная ошибка. Метрик Prometheus и Grafana нет.
- [ ] RPO 15 минут недостижим без WAL-архивирования: суточный дамп даёт сутки.
- [ ] Helm-путь экспериментальный: реальная установка в CI не гоняется, у workload'ов нет `securityContext` (только у `ntp`). Режимов TLS, шрифтов и сидов в чарте нет (Kubernetes использует свой ingress) — осознанное ограничение.
- [ ] На сервере `lct` проверить шрифты в `compose/fonts/` (в репозитории их быть не может).
- [ ] Репозиторий: удалить ветку бота `bot/update-images-35271171079`, применить ruleset к `.github` и включить `require_code_owner_review` (см. `REPO-SETTINGS.md`).
