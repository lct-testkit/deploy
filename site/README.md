# Сайт ИТ-Школы РТК

Laravel 12 (PHP 8.3) + PostgreSQL. Лендинг-каталог курсов, страница курса, форма заявки и API выдачи заявок для CRM
(`GET /api/v1/leads`). Интерфейс — Svelte 5 «острова» на дизайн-системе rt-ui поверх Blade (Vite).
Как включить в стенд и связать с CRM — [`../docs/site.md`](../docs/site.md).

## Устройство

```
app/Http/Controllers/SiteController.php      страницы и приём формы (honeypot, UTM-метка кампании)
app/Http/Controllers/Api/LeadController.php  API: курсорная пагинация по (updated_at, id), updated_since, limit <= 100
app/Http/Middleware/AuthenticateApiToken.php Bearer из SITE_API_TOKEN, сравнение через hash_equals; пустой токен = API закрыт
app/Http/Requests/ApplyRequest.php           валидация формы и тексты ошибок
app/Console/Commands/BootstrapDatabase.php   site:bootstrap-db — роль и БД, если их нет
config/courses.php                           каталог курсов (code = код продукта в CRM)
config/site.php                              настройки, общие блоки «Как проходит обучение» и FAQ
resources/js/islands/*.svelte                Svelte-острова: шапка, подвал, каталог, страница курса, форма, аккордеоны
resources/views/**                           Blade: каркас страницы и SSR-фолбэк (форма работает без JS)
resources/css/site.css                       только раскладка на токенах rt-ui; токены и компоненты ДС не переопределяются
docker/                                      nginx, php-fpm, php.ini, entrypoint
```

Контракт API (форма лида повторяет мок `mocks/cms`): `lead_id` (uuid), `name`, `phone`, `email`, `product_interest`
(код курса), `source_campaign`, `submitted_at`, `updated_at` + необязательные `organization`, `comment`. Время — UTC с
микросекундами (`2026-10-19T08:55:59.553376Z`), CRM сравнивает его как строку. `updated_since` — строго «новее».
Выдача скрывает заявки моложе `SITE_API_SETTLE_SECONDS` (2 с): транзакция, начатая раньше, но закоммиченная позже, иначе
проскочила бы мимо курсора CRM.

## Под префиксом `/site`

Сайт опубликован Caddy на `/site` (`handle_path` срезает префикс и передаёт `X-Forwarded-Prefix: /site`; Laravel доверяет
заголовкам прокси — `bootstrap/app.php`). Ссылки, форма, редиректы и ассеты Vite строятся с префиксом; Vite собран с
относительным `base: './'`. Напрямую в сети compose сайт доступен без префикса: `http://site:8080`.

## Сборка образа

```bash
# с токеном приватного пакета rt-ui (GitHub Packages, read:packages)
docker build --secret id=npm_token,env=NODE_AUTH_TOKEN -t rtk-site:local site/
```

Многостадийный Dockerfile: `assets` (node + pnpm + Vite, пакет rt-ui по BuildKit-секрету) → `vendor` (composer, без dev) → `base`
(php-fpm + nginx + pdo_pgsql) → `runtime`. База закреплена по digest.

Без токена (локально): rt-ui ставится из tarball `lct-testkit-rt-ui-0.1.1.tgz` (`npm pack` из репозитория rt-ui) через локальный
pnpmfile (`pnpm install --pnpmfile <pnpmfile.cjs>`, он подменяет зависимость без правки `package.json`; в репозитории остаётся
`"@lct-testkit/rt-ui": "0.1.1"` и `.npmrc` со scope, как во frontend). Затем `node_modules/.bin/vite build`, а образ собирается с подменой
стадии `assets` готовой сборкой: `docker build --target runtime --build-context assets=<каталог с app/public/build> site/`.

## Тесты

Feature-тесты (API: токен, пагинация, `updated_since`, лимиты, валидация; форма: поля, согласие, honeypot, throttle, CSRF,
префикс) идут на реальном PostgreSQL — на sqlite они не показали бы поведение микросекундных курсоров:

```bash
docker compose -f docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests
docker compose -f docker-compose.test.yml down -v
```

Исходные тексты курсов и политики — собственные; политика ПДн — шаблон, требует утверждения юристом.
