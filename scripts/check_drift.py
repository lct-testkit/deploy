#!/usr/bin/env python3
"""Сверяет compose/docker-compose.yml и charts/rtk-crm/values.yaml с
images.yaml — единым источником истины (см. `.github/workflows/validate.yml`,
джоб `drift`). Ловит ровно то, что иначе всплывёт как "в Helm задеплоен один
Postgres, а в compose — другой": кто-то поправил digest в одном месте и забыл
про второе.

Внешние образы (external.*) сверяются по digest (жёстко — оба пути обязаны
указывать ровно на тот образ, что зафиксирован в офлайн-бандле). Свои образы
(api/web) сверяются только по РЕГИСТРУ/ИМЕНИ (registry.host/project + имя) —
тег специально расходится в норме (`compose/.env.example` держит `latest` как
дефолт разработки, `values.yaml` — тоже `latest`; актуальный тег на конкретном
деплое приходит через `--env-file .env.images`/`--set` в момент раскатки, не
хранится вкомпилированным в эти файлы) — здесь только защита от опечатки в
самом имени образа/registry.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def load_yaml(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def main() -> int:
    images_doc = load_yaml(REPO_ROOT / "images.yaml")
    registry = images_doc["registry"]
    all_images = images_doc.get("images", {})
    external = images_doc.get("external", {})

    # И compose/, и values.yaml разворачивают только profiles.core (mock-lms/
    # mock-cms из profiles.integrations — заглушки внешних контрактов для CI
    # этого репозитория, не часть топологии docker-compose.yml/chart'а) —
    # сверяем по core, а не по всем images.yaml.images, иначе то, что оба
    # пути СОЗНАТЕЛЬНО не деплоят моки, выглядело бы как расхождение.
    core = set(images_doc.get("profiles", {}).get("core", []))
    own_images = {name for name in all_images if name in core}

    # --- compose: вытащить все "image: ...@sha256:..." строки -------------
    compose_path = REPO_ROOT / "compose" / "docker-compose.yml"
    compose_text = compose_path.read_text(encoding="utf-8")
    compose_digests: dict[str, str] = {}
    for m in re.finditer(r"^\s*image:\s*(\S+)@(sha256:[0-9a-f]{64})\s*$", compose_text, re.M):
        ref, digest = m.groups()
        # ref вида docker.io/library/postgres, docker.io/chrislusf/seaweedfs, quay.io/keycloak/keycloak...
        name = ref.rsplit("/", 1)[-1]
        compose_digests[name] = digest
    for m in re.finditer(r"^\s*image:\s*ghcr\.io/([^/]+)/([a-z0-9-]+):", compose_text, re.M):
        project, image = m.groups()
        if project != registry["project"]:
            err(f"compose: неожиданный registry project {project!r} у образа {image!r} "
                f"(images.yaml: {registry['project']!r})")
        elif image not in all_images:
            err(f"compose: образ {image!r} не описан в images.yaml.images")

    # --- values.yaml: images.<name>.{repository,tag,digest} ----------------
    values_doc = load_yaml(REPO_ROOT / "charts" / "rtk-crm" / "values.yaml")
    values_images = values_doc.get("images", {})
    if values_images.get("registry") != registry["host"] + "/" + registry["project"]:
        err(f"values.yaml: images.registry={values_images.get('registry')!r} расходится "
            f"с images.yaml ({registry['host']}/{registry['project']!r})")

    for name in own_images:
        spec = values_images.get(name)
        if not spec:
            err(f"values.yaml: нет images.{name} (есть в images.yaml.images)")
        elif spec.get("repository") != name:
            err(f"values.yaml: images.{name}.repository={spec.get('repository')!r}, ожидалось {name!r}")

    for name, ext in external.items():
        expected_digest = ext.get("digest", "")
        expected_name = ext["ref"].rsplit(":", 1)[0].rsplit("/", 1)[-1]

        c_digest = compose_digests.get(expected_name)
        if expected_digest and c_digest != expected_digest:
            err(f"compose: {expected_name} digest={c_digest!r}, "
                f"images.yaml.external.{name}={expected_digest!r}")

        v_spec = values_images.get(name)
        if v_spec is None:
            err(f"values.yaml: нет images.{name} (есть в images.yaml.external)")
            continue
        v_digest = v_spec.get("digest", "")
        if expected_digest and v_digest != expected_digest:
            err(f"values.yaml: images.{name}.digest={v_digest!r}, "
                f"images.yaml.external.{name}={expected_digest!r}")

    if errors:
        for e in errors:
            print(f"ERROR {e}", file=sys.stderr)
        print(f"\nрасхождение compose/values с images.yaml: {len(errors)} ошибок", file=sys.stderr)
        return 1

    print(f"ок: compose и values.yaml согласованы с images.yaml "
          f"({len(external)} внешних образов, {len(own_images)} своих)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
