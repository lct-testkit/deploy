#!/bin/sh
# Старт контейнера сайта: (1) роль/БД, (2) миграции, (3) демо-сид, (4) кэши, (5) php-fpm + nginx.
set -eu
cd /var/www/html

if [ -z "${APP_KEY:-}" ]; then
    # Без заданного ключа сессии и CSRF-токены переживают только до перезапуска контейнера.
    APP_KEY="$(php artisan key:generate --show)"
    export APP_KEY
    echo "WARN: APP_KEY не задан — сгенерирован временный; задайте SITE_APP_KEY в .env" >&2
fi
if [ -z "${SITE_API_TOKEN:-}" ]; then
    echo "WARN: SITE_API_TOKEN не задан — API /api/v1/leads отвечает 401 на любой запрос" >&2
fi

# База может подниматься параллельно (patroni, первый запуск postgres): ждём до ~3 минут.
n=0
until php artisan site:bootstrap-db && php artisan migrate --force --no-interaction; do
    n=$((n + 1))
    if [ "$n" -ge 90 ]; then
        echo "ERROR: БД недоступна или миграции не прошли" >&2
        exit 1
    fi
    sleep 2
done

php artisan db:seed --force --no-interaction
php artisan config:cache
php artisan route:cache
php artisan view:cache

php-fpm &
fpm=$!
nginx -e /dev/stderr -g 'daemon off;' &
web=$!

stop() { kill "$fpm" "$web" 2>/dev/null || true; }
trap stop TERM INT
# Падение любого из двух процессов — падение контейнера (restart: unless-stopped поднимет заново).
wait -n "$fpm" "$web" 2>/dev/null || wait "$fpm" "$web" || true
stop
wait || true
exit 1
