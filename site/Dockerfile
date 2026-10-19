# Сайт ИТ-Школы РТК (Laravel 12, PHP 8.3). Один контейнер: nginx + php-fpm под непривилегированным
# пользователем www-data, слушает 8080. Образ без dev-зависимостей; тесты — отдельный target `test`
# (docker compose -f docker-compose.test.yml up).
#
# Стадии: assets (Vite + Svelte + rt-ui) -> vendor (composer, прод-зависимости) -> base (php-fpm + nginx + pdo_pgsql) -> runtime.
# База закреплена по digest, как и остальные образы репозитория.
#
# Сборка фронтенда требует доступа к приватному пакету дизайн-системы @lct-testkit/rt-ui (GitHub Packages): токен передаётся
# BuildKit-секретом `npm_token` (docker build --secret id=npm_token,env=NODE_AUTH_TOKEN site/), как в frontend/Dockerfile.
# Шрифт Rostelecom Basis в образ не входит: страница берёт его с /fonts/* основного Caddy (см. compose/Caddyfile), без него — запасной шрифт темы.
# Локально без токена: собрать public/build на хосте и подменить стадию `docker build --build-context assets=./public/build-dir ...`
# (внутри контекста — содержимое public/build); подробности в site/README.md.

# --platform=$BUILDPLATFORM: результат — статика, от архитектуры не зависит; тяжёлые install/build идут нативно, не под QEMU.
FROM --platform=$BUILDPLATFORM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS assets
RUN npm install -g pnpm@11.13.1
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
# Токен — во временный USER-npmrc (pnpm 11 игнорирует авторизацию из .npmrc проекта), удаляется в том же RUN.
RUN --mount=type=secret,id=npm_token \
    --mount=type=cache,target=/root/.local/share/pnpm/store \
    printf '//npm.pkg.github.com/:_authToken=%s\n' "$(cat /run/secrets/npm_token)" > /tmp/npmrc \
    && NPM_CONFIG_USERCONFIG=/tmp/npmrc pnpm install --frozen-lockfile \
    && rm -f /tmp/npmrc
COPY vite.config.js ./
COPY resources ./resources
RUN mkdir -p public && ./node_modules/.bin/vite build

FROM --platform=$BUILDPLATFORM composer:2@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
# Платформенные проверки отключены: расширения (pdo_pgsql и др.) есть в стадии base, а не в composer-образе.
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction --ignore-platform-reqs
COPY app ./app
COPY bootstrap ./bootstrap
COPY config ./config
COPY database ./database
COPY routes ./routes
COPY artisan ./
RUN composer dump-autoload --no-dev --classmap-authoritative --no-interaction --ignore-platform-reqs

FROM php:8.3-fpm-alpine@sha256:454b11c8907e32878ce92e87b13c14e1bbe6e1b10f4f96d4a19c9b62ec675d41 AS base
# Патчи alpine на дату сборки (база не всегда содержит свежие security-фиксы своей ветки).
# Версии apk не пинуем: образ базы закреплён digest-ом, а `apk upgrade` намеренно берёт свежие фиксы ветки;
# $PHPIZE_DEPS — список пакетов, разбиение на слова здесь и нужно.
# hadolint ignore=DL3018,SC2086
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache nginx libpq; \
    apk add --no-cache --virtual .build-deps postgresql-dev $PHPIZE_DEPS; \
    docker-php-ext-install -j"$(nproc)" pdo_pgsql; \
    apk del .build-deps; \
    rm -rf /usr/local/etc/php-fpm.d/* /etc/nginx/http.d/* /tmp/*
COPY docker/php.ini /usr/local/etc/php/conf.d/zz-site.ini
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/zz-site.conf
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
WORKDIR /var/www/html

FROM base AS runtime
COPY --chown=www-data:www-data artisan composer.json ./
COPY --chown=www-data:www-data app ./app
COPY --chown=www-data:www-data bootstrap ./bootstrap
COPY --chown=www-data:www-data config ./config
COPY --chown=www-data:www-data database ./database
COPY --chown=www-data:www-data public ./public
COPY --chown=www-data:www-data resources ./resources
COPY --chown=www-data:www-data routes ./routes
COPY --chown=www-data:www-data storage ./storage
COPY --from=vendor --chown=www-data:www-data /app/vendor ./vendor
COPY --from=assets --chown=www-data:www-data /app/public/build ./public/build
RUN mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && rm -f bootstrap/cache/*.php

ENV APP_ENV=production \
    APP_DEBUG=false \
    LOG_CHANNEL=stderr \
    SESSION_DRIVER=file \
    CACHE_STORE=file \
    DB_CONNECTION=pgsql

USER www-data
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/up"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Тесты: dev-зависимости, исходники тестов, php artisan test. Не попадает в итоговый образ (target runtime).
FROM base AS test
COPY --from=composer:2@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac /usr/bin/composer /usr/bin/composer
COPY composer.json composer.lock ./
RUN composer install --no-scripts --no-autoloader --prefer-dist --no-interaction --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --no-interaction --ignore-platform-reqs && mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
CMD ["vendor/bin/phpunit"]
