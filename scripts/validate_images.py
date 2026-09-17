#!/usr/bin/env python3
"""Проверка images.yaml — единого источника истины по образам.

Ловит ровно те ошибки, которые иначе всплывут на раскатке:
опечатку в имени сервиса, битый digest, сервис без образа,
непиненный внешний образ в офлайн-бандле.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
KNOWN_REPOS = {"backend", "frontend", "deploy"}

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def check_images(doc: dict) -> set[str]:
    images = doc.get("images")
    if not isinstance(images, dict) or not images:
        err("images: пусто или не словарь")
        return set()

    for name, spec in images.items():
        where = f"images.{name}"
        if not NAME_RE.match(str(name)):
            err(f"{where}: имя должно быть lowercase-кебабом")
        if not isinstance(spec, dict):
            err(f"{where}: ожидается словарь")
            continue

        repo = spec.get("repo")
        if repo not in KNOWN_REPOS:
            err(f"{where}.repo={repo!r}: ожидается один из {sorted(KNOWN_REPOS)}")
        if not spec.get("context"):
            err(f"{where}.context: не задан")
        if not spec.get("dockerfile"):
            err(f"{where}.dockerfile: не задан")

        tag = spec.get("tag", "")
        digest = spec.get("digest", "")
        if tag and not TAG_RE.match(tag):
            err(f"{where}.tag={tag!r}: недопустимый тег")
        if digest and not DIGEST_RE.match(digest):
            err(f"{where}.digest={digest!r}: ожидается sha256:<64 hex>")
        if bool(tag) != bool(digest):
            err(f"{where}: tag и digest заполняются вместе (сейчас tag={tag!r}, digest={digest!r})")
        if not tag:
            warn(f"{where}: образ ещё не собран — деплой этим манифестом невозможен")

    return set(images)


def check_services(doc: dict, image_names: set[str]) -> set[str]:
    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        err("services: пусто или не словарь")
        return set()

    for svc, image in services.items():
        if not NAME_RE.match(str(svc)):
            err(f"services.{svc}: имя должно быть lowercase-кебабом")
        if image not in image_names:
            err(f"services.{svc} -> {image!r}: нет такого образа в images")

    unused = image_names - set(services.values())
    for image in sorted(unused):
        warn(f"images.{image}: не используется ни одним сервисом")

    return set(services)


def check_external(doc: dict, taken: set[str]) -> set[str]:
    external = doc.get("external")
    if not isinstance(external, dict):
        err("external: не словарь")
        return set()

    for name, spec in external.items():
        where = f"external.{name}"
        if name in taken:
            err(f"{where}: имя конфликтует с сервисом из services")
        if not isinstance(spec, dict):
            err(f"{where}: ожидается словарь")
            continue

        ref = spec.get("ref", "")
        if "/" not in ref or ":" not in ref.rsplit("/", 1)[-1]:
            err(f"{where}.ref={ref!r}: нужен полный ref с тегом (host/path:tag)")

        digest = spec.get("digest", "")
        if digest and not DIGEST_RE.match(digest):
            err(f"{where}.digest={digest!r}: ожидается sha256:<64 hex>")
        if not digest:
            warn(f"{where}: не запинен по digest — офлайн-бандл будет невоспроизводим")

    return set(external)


def check_profiles(doc: dict, known: set[str]) -> None:
    profiles = doc.get("profiles")
    if not isinstance(profiles, dict):
        err("profiles: не словарь")
        return

    seen: set[str] = set()
    for profile, members in profiles.items():
        if not isinstance(members, list):
            err(f"profiles.{profile}: ожидается список")
            continue
        for m in members:
            if m not in known:
                err(f"profiles.{profile}: {m!r} — нет ни в services, ни в external")
            if m in seen:
                err(f"profiles.{profile}: {m!r} уже входит в другой профиль")
            seen.add(m)

    for name in sorted(known - seen):
        warn(f"{name}: не отнесён ни к одному профилю")


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "images.yaml")
    if not path.exists():
        print(f"нет файла {path}", file=sys.stderr)
        return 1

    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        print(f"{path}: корень должен быть словарём", file=sys.stderr)
        return 1

    if doc.get("version") != 1:
        err(f"version={doc.get('version')!r}: поддерживается только 1")

    registry = doc.get("registry") or {}
    for key in ("host", "project"):
        if not registry.get(key):
            err(f"registry.{key}: не задан")

    image_names = check_images(doc)
    service_names = check_services(doc, image_names)
    external_names = check_external(doc, service_names)
    check_profiles(doc, service_names | external_names)

    for w in warnings:
        print(f"WARN  {w}")
    for e in errors:
        print(f"ERROR {e}", file=sys.stderr)

    if errors:
        print(f"\n{path}: {len(errors)} ошибок", file=sys.stderr)
        return 1

    print(f"\n{path}: ок ({len(image_names)} образов, {len(service_names)} сервисов, "
          f"{len(warnings)} предупреждений)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
