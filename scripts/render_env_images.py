#!/usr/bin/env python3
"""Генерирует `.env.images` — ссылки на ВСЕ образы стека из images.yaml.

compose/docker-compose.yml не содержит литералов образов: каждый `image:` —
переменная `<ИМЯ>_IMAGE` (API_IMAGE, WEB_IMAGE, POSTGRES_IMAGE, ...). Так
images.yaml — действительно единственный источник истины, а «в compose один
digest, в манифесте другой» невозможно по построению.

    python scripts/render_env_images.py [images.yaml] > compose/.env.images

Режимы (`--mode`):
  digest    (по умолчанию) — `repo:tag@sha256:…`: онлайн-деплой, образ
            проверяется по digest.
  bundle    — `rtk-offline/<имя>:<тег>`: имена, под которыми образы лежат в
            офлайн-бандле после `docker load` (см. scripts/build_offline_bundle.sh).
            Целостность обеспечивают SHA256SUMS и подпись бандла, а не digest
            в рантайме: у образов, загруженных `docker load`, нет RepoDigests,
            и ссылка вида `repo@sha256:…` заставила бы docker идти в сеть.
  registry  — `<--registry>/<имя>:<тег>`: внутренний registry контура,
            куда образы залиты scripts/registry_load.sh.

`--list` печатает TSV `имя<TAB>источник(digest)<TAB>bundle<TAB>registry` —
для scripts/build_offline_bundle.sh и scripts/registry_load.sh.

Пустой tag/digest у собственного образа — ошибка (деплой таким манифестом
невозможен); `--allow-missing` пропускает такие образы с предупреждением.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

BUNDLE_PREFIX = "rtk-offline"


def _var(name: str) -> str:
    return re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_IMAGE"


def _sanitize_tag(tag: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "-", tag)[:128]


def collect(doc: dict, allow_missing: bool) -> tuple[list[dict], list[str]]:
    """Список образов: name, var, source (digest-ссылка), tag (локальный тег)."""
    registry = doc["registry"]
    base = f"{registry['host']}/{registry['project']}"
    items: list[dict] = []
    missing: list[str] = []

    for name, spec in (doc.get("images") or {}).items():
        tag, digest = spec.get("tag", ""), spec.get("digest", "")
        if not tag or not digest:
            missing.append(f"images.{name}")
            continue
        items.append(
            {
                "name": name,
                "var": _var(name),
                "source": f"{base}/{name}:{tag}@{digest}",
                "tag": _sanitize_tag(tag),
            }
        )

    for name, spec in (doc.get("external") or {}).items():
        ref, digest = spec.get("ref", ""), spec.get("digest", "")
        if not digest:
            missing.append(f"external.{name}")
            continue
        repo, _, ref_tag = ref.rpartition(":")
        items.append(
            {
                "name": name,
                "var": _var(name),
                "source": f"{ref}@{digest}",
                "tag": _sanitize_tag(f"{ref_tag}-{digest.split(':')[1][:12]}"),
            }
        )
        del repo

    if missing and not allow_missing:
        raise SystemExit("нет tag/digest: " + ", ".join(missing))
    for m in missing:
        print(f"WARN {m}: нет tag/digest — образ пропущен (--allow-missing)", file=sys.stderr)
    return items, missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("images", nargs="?", default="images.yaml")
    parser.add_argument("--mode", choices=["digest", "bundle", "registry"], default="digest")
    parser.add_argument("--registry", default="", help="host:port внутреннего registry (для mode=registry/--list)")
    parser.add_argument("--list", action="store_true", help="TSV: имя, источник, bundle-ссылка, registry-ссылка")
    parser.add_argument("--allow-missing", action="store_true")
    args = parser.parse_args()

    doc = yaml.safe_load(Path(args.images).read_text(encoding="utf-8"))
    items, _ = collect(doc, args.allow_missing)

    if args.mode == "registry" and not args.registry:
        parser.error("--mode registry требует --registry host:port")

    def bundle_ref(it: dict) -> str:
        return f"{BUNDLE_PREFIX}/{it['name']}:{it['tag']}"

    def registry_ref(it: dict) -> str:
        return f"{args.registry}/{it['name']}:{it['tag']}" if args.registry else ""

    if args.list:
        for it in items:
            print("\t".join([it["name"], it["source"], bundle_ref(it), registry_ref(it)]))
        return 0

    pick = {
        "digest": lambda it: it["source"],
        "bundle": bundle_ref,
        "registry": registry_ref,
    }[args.mode]
    print(f"# Сгенерировано render_env_images.py (mode={args.mode}) — не редактировать руками.")
    for it in items:
        print(f"{it['var']}={pick(it)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
