#!/usr/bin/env python3
"""Проставляет tag/digest собранного образа в images.yaml.

Вызывается из build.yml после push в GHCR — по одному разу на образ:

    python scripts/update_image_refs.py mock-lms sha-abc1234 sha256:<64hex>

Использует ruamel.yaml (round-trip): комментарии и форматирование остального
файла не теряются, в отличие от yaml.safe_load + yaml.dump через pyyaml.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from ruamel.yaml import YAML

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "использование: update_image_refs.py <image> <tag> <digest>",
            file=sys.stderr,
        )
        return 1

    image, tag, digest = sys.argv[1:4]
    path = Path("images.yaml")

    if not TAG_RE.match(tag):
        print(f"tag={tag!r}: недопустимый формат", file=sys.stderr)
        return 1
    if not DIGEST_RE.match(digest):
        print(f"digest={digest!r}: ожидается sha256:<64 hex>", file=sys.stderr)
        return 1

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096  # не переносить строки при обратной записи
    # Отступ списков как в исходном файле: элемент на 2 глубже родителя,
    # тире с отступом offset=2 от родителя (иначе ruamel даёт "- x" вровень
    # с ключом, и yamllint indentation ругается на несовпадение).
    yaml.indent(mapping=2, sequence=4, offset=2)

    # newline="\n": репозиторий фиксирует LF через .gitattributes, а текстовый
    # режим на Windows иначе переводит \n в \r\n при записи.
    with path.open(encoding="utf-8", newline="\n") as f:
        doc = yaml.load(f)

    images = doc.get("images") or {}
    if image not in images:
        print(f"images.{image}: нет такого образа в {path}", file=sys.stderr)
        return 1

    images[image]["tag"] = tag
    images[image]["digest"] = digest

    with path.open("w", encoding="utf-8", newline="\n") as f:
        yaml.dump(doc, f)

    print(f"images.{image}: tag={tag} digest={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
