# CI на self-hosted раннере

У организации `lct-testkit` отключён биллинг GitHub Actions: задачи на `ubuntu-latest` не получают раннер и падают
за пару секунд. Поэтому вся цепочка — проверки, публикация образов, `notify`, e2e стека — идёт на собственных
раннерах с меткой `lct` (`runs-on: [self-hosted, lct]`). Метка объявлена в `.github/actionlint.yaml`.

## Что где идёт

| Что | Где | Замечание |
|---|---|---|
| lint / тесты / security backend и frontend | self-hosted | три экземпляра раннера на репозиторий, у каждого свой `$HOME` (кэши не гоняются) |
| публикация образов (`docker-publish.yml`) | self-hosted | multi-arch: linux/amd64 (эмуляция QEMU) + linux/arm64 (нативно); Trivy по каждой платформе; подпись cosign |
| `notify` (запись tag/digest в `images.yaml`) | self-hosted | до записи проверяет платформы образа (`REQUIRE_ARCHES`) и поднимает стек из образов |
| `e2e / stack` (up → smoke → бэкап → восстановление) | self-hosted | у каждого прогона свой compose-проект и свободные порты (`E2E_PROJECT`, `E2E_PORT_OFFSET=auto`) |
| `build.yml` (образы моков) | `ubuntu-latest` | не мигрирован — редкие триггеры (только изменения в `mocks/**` или ручной запуск), последний прогон 25.09.2026 успешен, но это было ДО отключения биллинга; при нынешнем биллинге упадёт как любой другой `ubuntu-latest`-джоб (см. первый абзац) — не проверено намеренно, чтобы не публиковать мок-образы без нужды |
| `e2e / offline-bundle` (установка без сети) | `ubuntu-latest` | режет сеть iptables и делает `docker system prune` — на общем демоне недопустимо; сейчас не выполняется |
| ночная нагрузка backend (`loadtest.yml`) | приостановлена | 50 RPS на 2 vCPU с девятью раннерами измерили бы раннер, а не код; запуск вручную на стенде |

## Архитектура раннера

Раннер — aarch64 (2 vCPU, ~11 ГиБ). Прод (стенд `lct.velikoss.ru`) — x86_64, поэтому образы обязаны быть multi-arch:
образ, собранный на раннере без `platforms:`, был бы arm64-only и не запустился на проде. Защита от этого:
`docker-publish.yml` собирает обе платформы и проверяет их в опубликованном индексе, а `scripts/verify_image.sh`
с `REQUIRE_ARCHES="amd64 arm64"` отклоняет образ без любой из них.

**Что покрывает CI.** Стек в e2e поднимается на нативных arm64-вариантах. amd64-вариант, который уезжает на прод,
в CI не исполняется — его проверяют установка на стенде и `scripts/smoke.sh`.

## Как выпустить релиз, пока нет GitHub-hosted раннера

Штатный путь (тег `vX.Y.Z`) требует `ubuntu-latest`. Обходной — вручную:

```bash
gh workflow run release.yml -R lct-testkit/deploy \
  -f version=vX.Y.Z -f runner=self-hosted -f skip_offline_e2e=true
```

- бандл собирает aarch64-раннер, но `docker pull`/`docker save` идут с `--platform linux/amd64`
  (`BUNDLE_PLATFORM`), то есть в бандле x86_64-образы;
- e2e стека и подпись cosign идут как обычно;
- установка без сети в CI не проверяется — заметки релиза говорят об этом прямо. Проверьте вручную: скачайте архив,
  `sha256sum -c`, `cosign verify-blob`, `install.sh` на чистой машине.

## Возврат на GitHub-hosted

Когда биллинг вернётся: заменить `runs-on: [self-hosted, lct]` на `ubuntu-latest` в `validate.yml`, `notify.yml`,
`docker-publish.yml`, `e2e.yml` (job `stack`) и в workflow'ах backend/frontend, раскомментировать `schedule` в
`backend/.github/workflows/loadtest.yml`, вернуть ночной запуск `offline-bundle` (условие
`github.event_name != 'schedule'` в `e2e.yml`). Штатный релиз — снова просто тег.

## Гигиена общей машины

- e2e чистит за собой по меткам compose (`if: always()` в последнем шаге); зависшие проекты `rtk-e2e-*` можно снести
  вручную: `docker ps -aq --filter label=com.docker.compose.project=<имя> | xargs -r docker rm -f`.
- Токен `GHCR_PULL_TOKEN` живёт только в секретах репозитория; `docker/login-action` разлогинивается в конце job'а.
