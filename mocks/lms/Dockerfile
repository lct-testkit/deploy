# Мок LMS: сервер генерируется Stoplight Prism прямо из openapi.yaml,
# никакого серверного кода не пишем (спека §4.14).
#
# Многостадийность здесь не косметика: вторая стадия не тащит npm/apk кэш,
# оставшийся после глобальной установки в первой.
FROM node:25-alpine@sha256:bdf2cca6fe3dabd014ea60163eca3f0f7015fbd5c7ee1b0e9ccb4ced6eb02ef4 AS deps
RUN npm install -g @stoplight/prism-cli@5.16.0

FROM node:25-alpine@sha256:bdf2cca6fe3dabd014ea60163eca3f0f7015fbd5c7ee1b0e9ccb4ced6eb02ef4 AS runtime
# Патчи alpine (openssl и т.п.) на дату сборки — база node:24-alpine не
# всегда содержит последние security-фиксы своей же ветки.
RUN apk update && apk upgrade --no-cache
# Копируем весь пакет, а не /usr/local/bin/prism: это относительный симлинк
# на dist/index.js, и при копировании одного файла между стадиями он
# разрешается в момент COPY и ломается (require('yargs') не находит
# node_modules). Зовём node на реальный entry point напрямую.
COPY --from=deps /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY openapi.yaml /openapi.yaml

EXPOSE 4010
USER node

# wget уже есть в alpine (busybox) — ничего лишнего не ставим, тот же
# принцип, что и в backend/Dockerfile (там ради этого используют python -c).
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=5 \
    CMD ["wget", "-q", "-O-", "http://127.0.0.1:4010/health/live"]

ENTRYPOINT ["node", "/usr/local/lib/node_modules/@stoplight/prism-cli/dist/index.js", "mock", "-h", "0.0.0.0", "-p", "4010", "/openapi.yaml"]
