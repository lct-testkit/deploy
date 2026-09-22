#!/usr/bin/env python3
"""Читает images.yaml и печатает `.env`-фрагмент с тегами образов.

Используется `scripts/deploy.sh` перед `docker compose pull`: images.yaml —
источник истины по тому, какой тег сейчас актуален (его правит
`.github/workflows/notify.yml` после каждой успешной сборки backend/frontend),
а `compose/docker-compose.yml` читает теги из переменных окружения
(`${API_TAG:-latest}`, `${WEB_TAG:-latest}`) — этот скрипт связывает одно с
другим, не требуя yq/jq на целевой VM (только python3, который уже нужен
остальным скриптам репозитория).

    python scripts/render_env_images.py images.yaml > compose/.env.images

Печатает только строки для образов, у которых реально проставлен tag
(пропускает пустые — деплой этим образом всё равно невозможен, пусть
`docker compose pull` упадёт понятной ошибкой на отсутствующем теге, а не
на пустой переменной).
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

# images.yaml key -> .env var, которую читает compose/docker-compose.yml.
_ENV_VAR = {"api": "API_TAG", "web": "WEB_TAG"}


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "images.yaml")
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    images = doc.get("images", {})

    lines = ["# Сгенерировано render_env_images.py — не редактировать руками."]
    for image, var in _ENV_VAR.items():
        tag = (images.get(image) or {}).get("tag", "")
        if tag:
            lines.append(f"{var}={tag}")
        else:
            print(f"WARN images.{image}.tag пуст — {var} не выставлен, будет дефолт compose", file=sys.stderr)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
