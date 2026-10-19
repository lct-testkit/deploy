# HA на трёх узлах: Patroni + etcd + SeaweedFS

Как поднять RTK School CRM (compose-вариант, v0.6.1) так, чтобы падение любого одного узла не останавливало сервис:
база переключается на реплику сама, DNS переезжает на нового лидера, приложение стартует на нём без оператора, а файлы
(S3) лежат в двух копиях на разных площадках. Документ описывает схему, проверенную на трёх VPS (Москва, Санкт-Петербург,
Казань) стенда `lct.velikoss.ru`, и содержит все скрипты и конфиги.

## Схема

| Узел | Площадка | WireGuard | Роль |
|------|----------|-----------|------|
| n1 | Москва | 10.10.0.1 | основной лидер |
| n2 | Санкт-Петербург | 10.10.0.2 | реплика БД, копия файлов, голос в кворуме; `nofailover: true` |
| n3 | Казань | 10.10.0.3 | реплика БД, цель failover |

- **Сеть** — WireGuard-mesh `10.10.0.0/24` между узлами; etcd, Patroni, репликация и SeaweedFS ходят только по ней.
- **БД** — PostgreSQL 16 под Patroni, DCS — etcd v3 на всех трёх узлах (кворум 2 из 3), асинхронная потоковая репликация.
- **Приложение** — стек `docker-compose.yml` + `docker-compose.ha.yml` запущен **только на лидере**; реплики держат образы
  и конфиги, но стек на них остановлен. Контейнер `postgres` из compose в HA не нужен (подменён на `sleep infinity`),
  приложение ходит в Postgres хоста по имени `patroni-db` (host-gateway).
- **Файлы (S3)** — кластер SeaweedFS в `/opt/seaweed` на каждом узле (master + volume, три датацентра `dc1..dc3`,
  репликация `100` — две копии в разных ДЦ). Сервис `seaweedfs` основного стека на лидере — это filer + S3-шлюз:
  данные идут в кластер, метаданные filer лежат в Postgres (БД `seaweedfs`).
- **Почта (Mailpit)** — ловушка писем (профиль `mail`) на лидере хранит письма не в локальном файле, а в кластере rqlite
  (`/opt/rqlite` на каждом узле, запущен всегда, как etcd): после смены лидера новый Mailpit открывает те же письма.
  Подробности — раздел «Mailpit на rqlite».
- **DNS** — A-запись `lct.velikoss.ru` в Cloudflare; при смене лидера её обновляет скрипт.
- **TLS** — Caddy (`TLS_MODE=acme`); том `rtk-crm_caddy_data` лидер раз в 2 минуты раздаёт остальным узлам, чтобы после
  failover не выпускать сертификат заново (лимит Let's Encrypt на повторные выпуски).

## Как проходит failover

1. Лидер перестаёт обновлять ключ в etcd. Через 30–40 с (`ttl` 30 с + цикл `loop_wait` 10 с) реплика берёт ключ и
   становится `master`. Изолированный бывший лидер сам понижает себя («demoting self because DCS is not accessible»).
2. Patroni вызывает `/etc/patroni/cf_update_dns.sh` (события `on_start`, `on_restart`, `on_role_change`). Скрипт через
   `sudo` запускает `rtk-ha-stack.sh` отдельным systemd-юнитом — он не зависит от групп процесса Patroni и не умирает
   вместе с колбэком.
3. `rtk-ha-stack.sh` берёт **реальную** роль из REST Patroni (`127.0.0.1:8008/patroni`) и приводит узел к ней:
   primary → обновляет A-запись и делает `docker compose up -d`; не primary → `docker compose stop`. Скрипт идемпотентен
   и сериализован `flock`; журнал — `/var/log/patroni-cf.log`.
4. Клиенты видят новый адрес после истечения кэша DNS.

Замеры (18.10.2026): плановое переключение — новый лидер за ~5 с, приложение готово ещё через ~25 с; аварийная
изоляция лидера — новый лидер через 38 с, приложение готово через 62 с, приложение на старом лидере остановлено на
~75 с. Cloudflare отдаёт TTL 150 с, хотя скрипт ставит 60, поэтому клиенты в тестах переключались за 1–3 минуты.

## Что проверено

| Сценарий | Результат |
|----------|-----------|
| `patronictl switchover` n1 → n3, затем обратно n3 → n1 (возврат делался дважды) | сайт и Keycloak отвечают на новом лидере, объект S3, записанный до переключений, читается после каждого |
| Изоляция n1 от WireGuard на 150 с (`iptables DROP` на `wg0`) | n3 стал лидером за 38 с, DNS обновлён сразу, приложение готово через 62 с, n1 сам остановил стек и после снятия блокировки вернулся репликой (лаг 0, колбэк `on_start` оставил стек остановленным) |
| Остановка `seaweed-master` и `seaweed-volume` на n1 при работающем приложении | 15/15 чтений ранее записанных файлов, 15/15 записей новых и 15/15 чтений новых; после возврата узла данные целы, в топологии три ДЦ |
| Перенос DNS | во всех переключениях запись обновлялась (`success:true`), в конце совпадала с IP лидера на авторитативных серверах Cloudflare, 1.1.1.1 и 8.8.8.8 |

Не проверялись: жёсткая перезагрузка лидера (power-off), одновременная потеря двух узлов, чтение S3 с нового лидера во
время изоляции прежнего (по отдельности проверены переезд стека и устойчивость слоя хранения).

## Требования к узлам

- Docker + compose-плагин, образы `rtk-offline/*` загружены на **каждом** узле (стек должен подниматься без сети).
- На всех узлах идентичны `/opt/rtk-crm/compose/{docker-compose.yml,docker-compose.ha.yml,Caddyfile,.env,.env.images}` и
  `runtime/` (realm Keycloak, `s3.json`, `filer.toml`). Пути в `.env` (`SEAWEED_S3_CONFIG`) — абсолютные и одинаковые на
  всех узлах: bind-mount несуществующего пути Docker молча превращает в пустую директорию.
- Узел, который может стать лидером, должен поддерживать инструкции x86-64-v2 (`popcnt`, `sse4_2`): образ Keycloak
  собран на RHEL 9 и на «голом» QEMU-CPU падает с `Fatal glibc error: CPU does not support x86-64-v2`. Такой узел
  оставляйте репликой с `nofailover: true` или смените тип CPU на `host`/`x86-64-v2`.
- Базы создаются с коллацией `C.UTF-8` (не `ru_RU.utf8`): иначе узлы с другим дистрибутивом/glibc либо не примут
  подключения (нет локали), либо получат неконсистентные текстовые индексы.
- Для Mailpit на rqlite на каждом узле нужны `/opt/rqlite`, `/srv/rqlite` (владелец uid 1000) и загруженный офлайн образ `rqlite`.
- Файрвол ufw включён на всех узлах (см. приложение): без него REST API Patroni и Postgres торчат в интернет.

## Развёртывание

1. WireGuard между узлами, адреса `10.10.0.1..3` (вне рамок документа).
2. etcd v3 на каждом узле, слушает `127.0.0.1` и WG-адрес; Patroni (`/opt/patroni`, unit `patroni.service`, пользователь
   `postgres`) с `etcd3.hosts` на три узла. В `patroni.yml` включить колбэки и теги:

   ```yaml
   postgresql:
     callbacks:
       on_start:       /etc/patroni/cf_update_dns.sh
       on_restart:     /etc/patroni/cf_update_dns.sh
       on_role_change: /etc/patroni/cf_update_dns.sh
   tags:
     nofailover: false   # true для узла, который не должен становиться лидером
   ```
3. Создать БД с `C.UTF-8` и восстановить данные (`crm`, `keycloak`, `seaweedfs`; роли `crm`, `crm_app`, `seaweed`):

   ```sql
   CREATE DATABASE crm OWNER crm TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8';
   ```
4. SeaweedFS-кластер на каждом узле: `/opt/seaweed/docker-compose.yml` (приложение A), `/opt/seaweed/.env` с `NODE_IP`
   (WG-адрес узла) и `DC` (`dc1`/`dc2`/`dc3`), каталоги `/srv/seaweed/{master,volume}`. Репликацию держите `100`: при `200`
   запись встаёт, как только падает один из трёх узлов (для новых томов нужны три ДЦ).
5. `docker-compose.ha.yml` (приложение A) и `runtime/seaweedfs/filer.toml` положить в `/opt/rtk-crm/compose` на всех узлах;
   задать пароль роли: `ALTER ROLE seaweed PASSWORD '…'` и вписать его в `filer.toml` (права `600`).
6. Скрипты из приложения A: `/usr/local/sbin/rtk-ha-stack.sh`, `/usr/local/sbin/rtk-ha-trigger.sh` (755, root),
   `/etc/patroni/cf_update_dns.sh`, `/etc/sudoers.d/rtk-ha` (440), `/etc/patroni/cf.env`:

   ```bash
   CF_API_TOKEN=…   # токен Cloudflare с правом править DNS зоны
   ZONE_ID=…
   RECORD_ID=…      # ID A-записи
   DOMAIN=lct.velikoss.ru
   MY_IP=…          # публичный IP ЭТОГО узла
   ```
7. Синхронизация сертификата Caddy: общий ключ `/root/.ssh/rtk_sync` на всех узлах; в `authorized_keys` каждого — строка
   `from="10.10.0.0/24",command="/usr/bin/rrsync /var/lib/docker/volumes/rtk-crm_caddy_data/_data",restrict <публичный ключ>`;
   на узлах без стека заранее `docker volume create --label com.docker.compose.project=rtk-crm --label com.docker.compose.volume=caddy_data rtk-crm_caddy_data`;
   unit и timer из приложения A, `systemctl enable --now rtk-caddy-sync.timer`.
8. Первый запуск на лидере: `/usr/local/sbin/rtk-ha-trigger.sh manual master` — обновит DNS и поднимет стек.

## Mailpit на rqlite

Без этого Mailpit пишет письма в SQLite-файл тома `mailpit_data` на лидере, и после failover новый лидер показывает пустой
ящик. Поэтому в HA Mailpit хранит письма в [rqlite](https://rqlite.io) — распределённой SQLite на Raft (образ
`rqlite/rqlite`, multi-arch: подходит и для aarch64-, и для amd64-узлов; версия и digest — `external.rqlite` в
`images.yaml`, образ едет в офлайн-бандле вместе с остальными). Mailpit v1.31.6 умеет внешнюю БД из коробки:
`MP_DATABASE=http://логин:пароль@хост:4001` (compose-переменная `MAILPIT_DATABASE`), драйвер сам находит лидера кластера и
при отказе переходит на другие узлы.

Одиночный стенд ничего не меняет: `MAILPIT_DATABASE` пуста — письма лежат в файле `/data/mailpit.db`.

**Почему отдельный compose-проект, а не systemd-юнит и не часть основного стека.** rqlite нужен на всех трёх узлах постоянно
(иначе нет кворума 2 из 3), а основной стек `rtk-crm` на репликах остановлен — значит, в него rqlite не положить. Остаётся
отдельный проект `rtk-rqlite` в `/opt/rqlite`: ровно так же в этой схеме устроен SeaweedFS (`/opt/seaweed`, `network_mode: host`,
`restart: unless-stopped`, `.env` с адресом узла), образ грузится так же офлайн, обновление — тот же `docker compose pull/up`,
а отдельный systemd-юнит добавил бы второй способ запускать контейнеры. Файлы — `compose/ha/rqlite.yml`,
`compose/ha/rqlite.env.example`, `compose/ha/rqlite-auth.example.json`.

### Установка (на каждом из трёх узлов)

```bash
install -d -m 755 /opt/rqlite && install -d -o 1000 -g 1000 -m 700 /srv/rqlite   # uid 1000 — пользователь rqlite в образе
cp compose/ha/rqlite.yml /opt/rqlite/docker-compose.yml
cp compose/ha/rqlite.env.example /opt/rqlite/.env && chmod 600 /opt/rqlite/.env
cp compose/ha/rqlite-auth.example.json /opt/rqlite/auth.json && chmod 600 /opt/rqlite/auth.json
```

1. В `/opt/rqlite/.env`: `NODE_ID` (`n1`/`n2`/`n3`) и `NODE_IP` (WG-адрес узла) — свои на каждом узле;
   `RQLITE_IMAGE` — строка из `.env.images` основного стека (`grep '^RQLITE_IMAGE=' /opt/rtk-crm/compose/.env.images`),
   образ уже загружен офлайн (`rtk-offline/*`).
2. В `/opt/rqlite/auth.json` задать три пароля (**одинаковые на всех узлах**; только `[A-Za-z0-9]`, чтобы их можно было
   вставить в URL без экранирования, например `openssl rand -hex 24`): `mailpit` — для Mailpit (права `query`, `execute`,
   `status`; `status` обязателен — по нему драйвер узнаёт лидера), `cluster` — узлы друг для друга (`join`, `notify`), `admin` —
   оператору (`all`: проверка `/nodes`, бэкап). Без файла пользователей rqlite открыт всем, кто достанет до WG-адреса, —
   запускать без него нельзя; сам rqlite слушает только `NODE_IP`.
3. Файрвол: порты 4001/4002 доступны по `wg0` (правило `ufw allow in on wg0` уже есть), а Mailpit в контейнере ходит к rqlite
   своего узла по WG-адресу через docker-сеть — добавьте `4001` в правило для `172.16.0.0/12` (см. приложение, ufw).
4. Запустить на всех трёх узлах примерно одновременно (первый запуск ждёт остальных и пробует снова, пока не соберутся все
   три; `-bootstrap-expect 3`): `cd /opt/rqlite && docker compose up -d`. Позже узел можно перезапускать по одному — он
   вернётся в собранный кластер из сохранённого состояния.
5. Проверка (с любого узла, `A=admin:<пароль>`):

   ```bash
   curl -s -u $A 'http://10.10.0.1:4001/nodes' | jq 'map_values({api_addr, voter, reachable, leader})'   # три узла, один leader:true
   curl -s -u $A http://10.10.0.1:4001/readyz                                                           # [+]node ok, leader ok, store ok, db ok
   curl -s -u $A http://10.10.0.1:4001/status | jq '.store.raft.state, .store.leader.node_id'
   ```

   Без `-u` те же запросы возвращают 401.
6. В `/opt/rtk-crm/compose/.env` на **каждом** узле — `COMPOSE_PROFILES=mail` (если не стоит) и `MAILPIT_DATABASE` с адресом
   **rqlite этого же узла**. Это единственная строка `.env`, которая у узлов разная: Mailpit должен стартовать, даже когда
   остальные узлы недоступны, поэтому ходит в локальный rqlite, а остальной кластер находит сам.

   ```bash
   # n1; на n2 — 10.10.0.2, на n3 — 10.10.0.3
   MAILPIT_DATABASE='http://mailpit:<пароль mailpit>@10.10.0.1:4001/?disableClusterDiscovery=true&timeout=30'
   ```

   `disableClusterDiscovery=true` обязателен: без него Mailpit при подключении опрашивает `/nodes`, а при недоступном узле этот запрос
   висит ~30 с и Mailpit не стартует (проверено репетицией отключения Москвы 19.10.2026). Запись rqlite узла сам пересылает лидеру.

   `timeout=30` нужен потому, что при недоступном соседе запрос `/nodes` занимает около 6 с, а таймаут драйвера по умолчанию
   короче: при перезапуске в момент отказа узла Mailpit терял первую попытку подключения (в замерах справлялся со второй).
7. Применить на лидере: `/usr/local/sbin/rtk-ha-trigger.sh manual master` (пересоздаст `mailpit` с новой БД). Реплики
   подхватят значение при следующем failover.

Порядок на живом стенде: rqlite на трёх узлах и проверка кластера, затем `.env` и ufw на узлах, затем перезапуск стека на
лидере. Письма, которые уже лежат в файле `mailpit_data`, **не переносятся**: Mailpit сменит хранилище и начнёт с пустого
ящика (для ловушки писем это допустимо; старые письма остаются в томе, их можно снова открыть, вернув `MAILPIT_DATABASE=`).

### Что происходит при отказах

| Событие | Результат |
|---------|-----------|
| Failover Patroni (лидер меняется) | Mailpit нового лидера открывает тот же кластер: все письма на месте, новые принимаются |
| Падение одного узла (в том числе лидера rqlite) | кворум 2 из 3, rqlite выбирает нового лидера за секунды, Mailpit продолжает работать; вернувшийся узел догоняет данные сам |
| Потеря двух узлов | кворума нет: Mailpit **не принимает** письма (SMTP-клиенту отдаётся ошибка) и **не показывает** ящик (интерфейс и API отвечают ошибкой) — и чтение, и запись идут через лидера Raft. CRM при этом работает (Postgres под Patroni — отдельный кворум). Как только возвращается второй узел, почта оживает без вмешательства |

### Бэкап

Раз в сутки на любом узле (письма в ловушке не критичны, но снимок дёшев):

```bash
curl -s -u admin:<пароль> http://10.10.0.1:4001/db/backup -o /var/backups/mailpit-$(date +%F).sqlite
```

Файл — обычный SQLite (`sqlite3 … 'select count(*) from mailbox'`). Восстановление — `POST /db/load` тем же файлом на
работающем кластере: `curl -u admin:… -H 'Content-Type: application/octet-stream' --data-binary @файл http://10.10.0.1:4001/db/load`.
Данные самих узлов лежат в `/srv/rqlite`.

## Грабли, на которые мы наступили

- Колбэк, запущенный из процесса Patroni, наследует его группы: если `postgres` добавили в `docker` уже после старта
  Patroni, `docker`/`.env` недоступны («permission denied»). Поэтому колбэк идёт через `sudo` → `systemd-run`.
- `docker compose stop a b nonexistent` не останавливает **ничего**: устаревшее имя сервиса в команде означало, что
  демотированный узел продолжал держать стек. Теперь `stop` без списка сервисов.
- Образ SeaweedFS-filer в контейнере ходит к master-у на хост по WG-адресу; правила ufw для docker-сетей
  (`172.16.0.0/12`) должны пускать 9333 и 19333, иначе filer бесконечно «ждёт мастера».
- filer не должен ходить в Postgres по публичному имени домена: он попадёт под файрвол. Используйте `patroni-db`.
- Сертификат Caddy без синхронизации перевыпускается на каждом новом лидере.

## Эксплуатация

```bash
patronictl -c /etc/patroni/patroni.yml list                                                 # состояние кластера
patronictl -c /etc/patroni/patroni.yml switchover crm --leader n1 --candidate n3 --force    # плановое переключение
tail -f /var/log/patroni-cf.log                                                             # что делал колбэк
systemctl list-timers rtk-caddy-sync.timer                                                  # синхронизация сертификата
curl -s http://10.10.0.1:9333/dir/status | jq '.Topology.DataCenters[].Id'                  # топология SeaweedFS
curl -s -u admin:… http://10.10.0.1:4001/nodes                                              # кластер rqlite (почта Mailpit)
```

## Ограничения

- Репликация Postgres асинхронная: при внезапной потере лидера теоретически теряются последние миллисекунды коммитов.
  Вариант — `synchronous_mode: true`; тогда на узле с `nofailover` нужно ещё `nosync: true`, иначе Patroni может выбрать
  его синхронной репликой и не повысит другой узел.
- Сессии (Redis, Keycloak) живут на лидере и при failover сбрасываются: пользователям нужно войти заново.
- Доступность для клиентов ограничена кэшем DNS (в тестах 1–3 минуты). Если колбэк не смог обновить DNS за 5 попыток,
  запись нужно поправить вручную или повторить `rtk-ha-trigger.sh manual master` на лидере.
- Бэкапов по расписанию нет — настройте `pg_dump` на лидере и копирование данных S3; для почты — `/db/backup` rqlite (см. выше).
- rqlite и Mailpit на живом HA-стенде (WireGuard, три VPS) не проверялись: схема отработана локально на трёх контейнерах
  rqlite в отдельной docker-сети (переключение Mailpit между узлами, догон вернувшегося узла, потеря кворума).

## Приложение A. Скрипты и конфиги

### `/usr/local/sbin/rtk-ha-stack.sh`

```bash
#!/bin/bash
# Приводит стек приложения на этом узле в соответствие с ролью Patroni (идемпотентно).
#   rtk-ha-stack.sh <событие> <роль-из-колбэка>
# Запускается из rtk-ha-trigger.sh в отдельном systemd-юните: не умирает вместе с колбэком
# Patroni и не зависит от групп процесса Patroni (docker.sock, .env).
EVENT=${1:-manual}; HINT=${2:-}
LOG=/var/log/patroni-cf.log
exec 9>/run/rtk-ha-stack.lock
flock 9
log() { echo "$(date -Is) [$(hostname)] $*" >> "$LOG"; }
is_primary() { [[ "$1" == master || "$1" == primary ]]; }

# Истина — REST Patroni; подсказка из колбэка нужна, только чтобы дождаться смены роли.
ROLE=""
for _ in $(seq 1 15); do
  ROLE=$(curl -s -m 3 http://127.0.0.1:8008/patroni | jq -r '.role // empty' 2>/dev/null)
  if is_primary "$HINT"; then is_primary "$ROLE" && break
  else [[ -n "$ROLE" ]] && ! is_primary "$ROLE" && break; fi
  sleep 2
done
[[ -z "$ROLE" ]] && ROLE=$HINT

source /etc/patroni/cf.env
cd /opt/rtk-crm/compose || { log "нет /opt/rtk-crm/compose"; exit 0; }
COMPOSE=(docker compose -p rtk-crm -f docker-compose.yml -f docker-compose.ha.yml --env-file .env --env-file .env.images)

if is_primary "$ROLE"; then
  log "$EVENT: primary -> DNS $DOMAIN=$MY_IP, стек up"
  for i in 1 2 3 4 5; do
    out=$(curl -s -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${MY_IP}\",\"ttl\":60,\"proxied\":false}")
    log "dns try $i: $(echo "$out" | jq -c '{success, errors, ip: .result.content}' 2>/dev/null || echo "$out")"
    [[ "$(echo "$out" | jq -r '.success' 2>/dev/null)" == true ]] && break
    sleep 3
  done
  if "${COMPOSE[@]}" up -d --remove-orphans >> "$LOG" 2>&1; then log "стек up: ok"; else log "стек up: ОШИБКА rc=$?"; fi
else
  log "$EVENT: role=${ROLE:-?} -> стек stop"
  if "${COMPOSE[@]}" stop >> "$LOG" 2>&1; then log "стек stop: ok"; else log "стек stop: ОШИБКА rc=$?"; fi
fi
```

### `/usr/local/sbin/rtk-ha-trigger.sh`

```bash
#!/bin/bash
# sudo-обёртка для колбэка Patroni (postgres -> root): запускает rtk-ha-stack.sh отдельным юнитом.
[[ "$1" =~ ^[a-z_]+$ && "$2" =~ ^[a-z_]*$ ]] || exit 1
exec systemd-run --no-block --collect --quiet --unit="rtk-ha-stack-$(date +%s%N)" \
  /usr/local/sbin/rtk-ha-stack.sh "$1" "$2"
```

### `/etc/patroni/cf_update_dns.sh`

```bash
#!/bin/bash
# Колбэк Patroni: <action> <role> <scope>. Вся работа — в /usr/local/sbin/rtk-ha-stack.sh.
exec sudo -n /usr/local/sbin/rtk-ha-trigger.sh "$1" "$2"
```

### `/etc/sudoers.d/rtk-ha`

```
postgres ALL=(root) NOPASSWD: /usr/local/sbin/rtk-ha-trigger.sh
```

### `/usr/local/sbin/rtk-caddy-sync.sh`, `rtk-caddy-sync.service`, `rtk-caddy-sync.timer`

```bash
#!/bin/bash
# Раз в пару минут лидер Patroni раздаёт ACME-хранилище Caddy (сертификаты) остальным узлам,
# чтобы после failover новый лидер не выпускал сертификат заново (лимит Let's Encrypt).
[[ "$(curl -s -m 3 http://127.0.0.1:8008/patroni | jq -r '.role // empty')" =~ ^(master|primary)$ ]] || exit 0
SRC=/var/lib/docker/volumes/rtk-crm_caddy_data/_data/
[[ -d "$SRC" ]] || exit 0
for ip in 10.10.0.1 10.10.0.2 10.10.0.3; do
  ip -4 -o addr show | grep -q " $ip/" && continue
  rsync -a -e "ssh -i /root/.ssh/rtk_sync -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new" \
    "$SRC" "root@$ip:./" || echo "caddy-sync -> $ip: ошибка" >&2
done
```

```ini
[Unit]
Description=Sync Caddy ACME storage from Patroni primary to peers
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rtk-caddy-sync.sh
```

```ini
[Unit]
Description=Sync Caddy ACME storage every 2 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
```

### `/opt/rtk-crm/compose/docker-compose.ha.yml`

```yaml
x-db: &db
  DATABASE_URL: postgresql+asyncpg://crm_app:${CRM_APP_PASSWORD}@patroni-db:5432/${POSTGRES_DB:-crm}
  KC_DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-crm}:${POSTGRES_PASSWORD}@patroni-db:5432/keycloak
  WAIT_FOR_POSTGRES: patroni-db:5432
x-host: &host
  extra_hosts:
    - "patroni-db:host-gateway"
services:
  postgres:
    entrypoint: ["sleep", "infinity"]
    command: []
    healthcheck:
      test: ["CMD", "true"]
      interval: 5s
      timeout: 2s
      retries: 3
      start_period: 1s
  api:      { <<: *host, environment: *db }
  worker:   { <<: *host, environment: *db }
  seed:     { <<: *host, environment: *db }
  migrate:
    <<: *host
    environment:
      <<: *db
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-crm}:${POSTGRES_PASSWORD}@patroni-db:5432/${POSTGRES_DB:-crm}
  keycloak:
    <<: *host
    environment:
      <<: *db
      KC_DB_URL: jdbc:postgresql://patroni-db:5432/keycloak

  # SeaweedFS: filer+S3 живут в стеке на лидере, данные — в трёхузловом кластере /opt/seaweed
  # (master+volume на каждом узле, репликация 100 = две копии в разных ДЦ), метаданные filer — в Postgres.
  seaweedfs:
    <<: *host
    command: >
      filer
      -master=10.10.0.1:9333,10.10.0.2:9333,10.10.0.3:9333
      -port=8888
      -defaultReplicaPlacement=100
      -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json
    volumes:
      - ./runtime/seaweedfs/filer.toml:/etc/seaweedfs/filer.toml:ro
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8888/ || exit 1"]
```

### `/opt/rtk-crm/compose/runtime/seaweedfs/filer.toml`

```toml
[postgres2]
enabled = true
createTable = """
  CREATE TABLE IF NOT EXISTS "%s" (
    dirhash BIGINT, name VARCHAR(65535), directory VARCHAR(65535), meta bytea,
    PRIMARY KEY (dirhash, name)
  );
"""
hostname = "patroni-db"   # host-gateway: Postgres на этом же узле (стек живёт только на лидере)
port = 5432
username = "seaweed"
password = "<пароль роли seaweed>"
database = "seaweedfs"
sslmode = "disable"
connection_max_idle = 5
connection_max_open = 20
```

### `/opt/seaweed/docker-compose.yml` (на каждом узле, `.env` — `NODE_IP`, `DC`)

```yaml
x-sw: &sw
  image: rtk-offline/seaweedfs:3.68-172f7f002fb5
  network_mode: host
  restart: unless-stopped
services:
  master:
    <<: *sw
    command: >-
      master -ip=${NODE_IP} -port=9333 -mdir=/data/master
      -peers=10.10.0.1:9333,10.10.0.2:9333,10.10.0.3:9333
      -defaultReplication=100 -volumeSizeLimitMB=1024 -volumePreallocate=false
    volumes: ["/srv/seaweed/master:/data/master"]
  volume:
    <<: *sw
    command: >-
      volume -ip=${NODE_IP} -port=8080 -dir=/data/volume -max=0
      -mserver=10.10.0.1:9333,10.10.0.2:9333,10.10.0.3:9333
      -dataCenter=${DC} -rack=r1
    volumes: ["/srv/seaweed/volume:/data/volume"]
```

### ufw (на каждом узле; публичные адреса узлов подставьте свои)

```bash
ufw default deny incoming; ufw default allow outgoing; ufw default deny routed
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 8333/tcp
for ip in <IP_n1> <IP_n2> <IP_n3>; do ufw allow proto udp from $ip to any port 51820; done
ufw allow in on wg0
ufw allow proto tcp from 172.16.0.0/12 to any port 4001,5432,8333,8080,8888,9333,18080,18888,19333
ufw --force enable
```
