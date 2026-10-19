# Сайт ИТ-Школы РТК (Laravel) — источник заявок для CRM

ТЗ: CRM забирает заявки из двух источников по API — LMS и веб-сайта на CMS Laravel. Раньше вместо сайта работал мок
`mocks/cms` (Prism по OpenAPI); теперь есть настоящий сайт — каталог `site/` (Laravel 12, PHP 8.3, PostgreSQL), сервис
compose `site` под профилем `site`. Устройство приложения, тесты и локальная разработка — в [`site/README.md`](../site/README.md);
здесь — как включить его в стенд и связать с CRM.

## Что это за сервис

- Лендинг-каталог курсов, страница курса (о программе, навыки, модули, FAQ), форма заявки с обязательным согласием на обработку
  ПДн, страница политики, honeypot + throttle (5 заявок в минуту с адреса) + CSRF. Интерфейс собран на дизайн-системе rt-ui
  (Svelte-«острова» поверх Blade; форма работает и без JS обычным POST).
- API для CRM по контракту бэкенда (`app/modules/integration/cms_client.py`):
  `GET /api/v1/leads?updated_since=&cursor=&limit=` → `{"items": [...], "next_cursor": "..."|null}`,
  `GET /api/v1/leads/{id}`; `Authorization: Bearer <токен>`, без токена — 401, `limit` ≤ 100.
- БД PostgreSQL: отдельная база `site` и роль `site`. Контейнер сам создаёт их при старте (если заданы учётные данные
  администратора PostgreSQL), применяет миграции и, при `SITE_SEED_DEMO=true`, заводит 4 демо-заявки в пустую таблицу.
- Образ `site` (`php:8.3-fpm-alpine` + nginx, non-root `www-data`, порт 8080, healthcheck `/up`, ~190 МБ, Trivy: 0 HIGH/CRITICAL).

## Включить в стенд

```bash
# 1. .env: секреты сайта создаёт gen_env.sh (SITE_APP_KEY, SITE_DB_PASSWORD, CMS_AUTH_TOKEN). Вручную — см. таблицу ниже.
# 2. Образ: `site` публикует build.yml, ссылка на него (tag/digest) уже в images.yaml и попадает в .env.images
python scripts/render_env_images.py > .env.images
docker compose --env-file .env --env-file .env.images --profile site pull site
docker compose --env-file .env --env-file .env.images --profile site up -d site
# 3. Caddy подхватит маршрут /site (перезапуск не нужен: апстрим резолвится по запросу)
curl -s http://localhost:8080/site/up     # 200
```

`build.yml` пушит `ghcr.io/lct-testkit/site` (только linux/amd64: все узлы стенда x86_64, на нём же, на раннере
с меткой `lct-x64`, образ и собирается) и бот вписывает tag/digest в `images.yaml`. Образ помечен там как `optional`:
пока его нет в манифесте, `render_env_images.py` подставляет локальный тег `rtk-site:local` и остальной деплой не
блокируется (собрать его можно локально: `docker compose --profile site up -d --build site`); опубликованный
образ едет в офлайн-бандле.

### Переменные (`.env`)

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `SITE_APP_KEY` | ключ Laravel (`base64:...`), gen_env.sh генерирует; пусто — временный ключ на каждый старт | — |
| `CMS_AUTH_TOKEN` | Bearer-токен API сайта; **один и тот же** читает CRM (через `CMS_AUTH_REF=CMS_AUTH_TOKEN`) и сайт (`SITE_API_TOKEN`). Пусто — API сайта закрыт (401) | gen_env.sh генерирует |
| `CMS_BASE_URL` | адрес сайта для CRM: `http://site:8080` (demo/dev) или публичный `https://<хост>/site` (prod) | пусто |
| `CMS_AUTH_REF` | имя переменной с токеном | `CMS_AUTH_TOKEN` |
| `SITE_DB_HOST` / `SITE_DB_PORT` / `SITE_DB_NAME` / `SITE_DB_USER` / `SITE_DB_PASSWORD` | БД сайта | `postgres` / `5432` / `site` / `site` / `site` (пароль gen_env.sh генерирует) |
| `SITE_DB_ADMIN_USER` / `SITE_DB_ADMIN_PASSWORD` | учётка администратора PostgreSQL для создания роли и БД при старте | `POSTGRES_USER` / `POSTGRES_PASSWORD` |
| `SITE_SEED_DEMO` | демо-заявки в пустую таблицу | `false` (на боевом сайте не включать: они попадут в CRM как настоящие) |
| `SITE_LOGIN_URL` | куда ведёт «Войти» в шапке | `/` (CRM на корне хоста) |
| `SITE_SECURE_COOKIES` | `true` при HTTPS (cookie сессии только по TLS) | пусто |
| `SITE_HOST`, `LMS_HOST` | отдельные имена хостов в Caddy, см. ниже | пусто |

### HA (Patroni)

В HA контейнер `postgres` из compose не используется, приложение ходит в Postgres хоста по имени `patroni-db`.
Для сайта: `SITE_DB_HOST=patroni-db`, `SITE_DB_PORT=5432`, `SITE_DB_ADMIN_USER`/`SITE_DB_ADMIN_PASSWORD` — суперпользователь
Patroni (нужен только для первого создания роли и БД; потом можно убрать). Сервис `site` не зависит от `postgres`
(`depends_on` нет): entrypoint сам ждёт БД до ~3 минут и применяет миграции на любом лидере. Алиас `patroni-db` прописан в
`extra_hosts` самого сервиса. Базу `site` включайте в бэкап Patroni наравне с `crm`/`keycloak`.

## Связать с CRM

1. В `.env`: `CMS_BASE_URL`, `CMS_AUTH_TOKEN` (gen_env.sh уже создал токен). `CMS_BASE_URL` и `CMS_AUTH_REF` долетают до
   `api`/`worker` (добавлены в `x-api-env`), токен — `CMS_AUTH_TOKEN`. Перезапустить `api` и `worker`.
2. Профиль `APP_PROFILE=prod` проверяет адрес источника строго (SSRF-защита): `http://site:8080` (приватная сеть compose)
   **отклоняется**. В prod укажите публичный адрес: `CMS_BASE_URL=https://<хост>/site` (или `https://school.<домен>` при `SITE_HOST`).
   В `demo`/`dev` работает `http://site:8080`.
3. Включить источник: `PATCH /api/admin/integrations/sources/cms` с `{"is_active": true, "pull_enabled": true}`
   (или «Настройка → Интеграции» в интерфейсе). Расписание — раз в `pull_interval_seconds` (по умолчанию 300 с).
4. «Забрать сейчас»: `POST /api/admin/integrations/sources/cms/pull` — запрос ставится в очередь и исполняется ближайшим
   тиком планировщика воркера (до минуты). Результат: `GET .../sources/cms/status` (`last_run`: fetched/created/failed).
5. Курс заявки передаётся кодом продукта CRM (`product_interest`: `devops`, `ds-pro`, `py-base`, `cyber`, `AST-SE`) —
   сделка получает продукт каталога CRM. Код курса на сайте = код продукта в CRM; новый курс добавляется в
   `site/config/courses.php` вместе с продуктом в каталоге CRM.

## Отдельные имена хостов (school / lms) вместо путей

`SITE_HOST=school.velikoss.ru` (и `LMS_HOST=lms.velikoss.ru`) в `.env` — Caddy заводит отдельный сайт по имени хоста с тем же
режимом TLS, что и основной (`TLS_MODE=acme` — Let's Encrypt HTTP-01, `internal` — самоподписанный). Пустая переменная — блока нет,
сайт остаётся на `/site`. Сертификаты лежат в томе `caddy_data` (в HA он уже синхронизируется между узлами). DNS (CNAME на
хост стенда) должен существовать до запуска, иначе выпуск сертификата упадёт. Сайт на отдельном хосте работает на корне
(без префикса), `/site` остаётся запасным вариантом.

Техника: адреса блоков Caddy приходят из compose переменными `SITE_ADDRESSES`/`LMS_ADDRESSES` («имя:порт, » или пусто);
к ним в Caddyfile дописан заведомо недоступный `http://127.0.0.1:6553x` (контейнерный, наружу не публикуется), чтобы ключ блока
не был пустым. `LMS_HOST` проксирует на `mock-lms:4010` (профиль `integrations`, без собственной авторизации — это мок).
`MAIL_HOST` (Mailpit, профиль `mail`) работает так же — отдельным host-блоком `MAIL_ADDRESSES`: переход на `/mail/` основного адреса CRM.

## Шрифт и дизайн-система

Интерфейс использует `@lct-testkit/rt-ui` (приватный пакет GitHub Packages). Шрифт Rostelecom Basis лицензионный и в образ и git
не входит: страница берёт его с `/fonts/*` того же хоста (его отдаёт Caddy из `FONTS_DIR`, как и для CRM). Без файлов шрифта
остаётся запасной шрифт браузера. В CI образ собирается с BuildKit-секретом `npm_token` (`NODE_AUTH_TOKEN`): у репозитория
deploy должен быть доступ к пакету rt-ui (Package → Manage Actions access) либо задан секрет организации `NODE_AUTH_TOKEN`.

## Проверка

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/site/                 # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/site/api/v1/leads     # 401 без токена
curl -s -H "Authorization: Bearer $CMS_AUTH_TOKEN" 'http://localhost:8080/site/api/v1/leads?limit=2'   # {"items":[...],"next_cursor":...}
```

Заявка через форму → `POST /site/apply` (302 на `/site/thanks`) → строка в `site.leads` → «Забрать сейчас» → сделка в CRM с продуктом.
Автотесты API и формы (30 тестов на реальном PostgreSQL): `docker compose -f site/docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests`.

## Персональные данные

В логах ПДн нет: nginx не пишет тела запросов, Laravel не логирует вход формы, исключения валидации не логируются, в query API —
только метки времени и курсор. Заявки хранятся в таблице `site.leads` (ФИО, телефон, e-mail, вуз, комментарий, момент согласия);
срок хранения и удаление — по политике оператора. Текст политики на сайте — шаблон, его должен утвердить юрист.
