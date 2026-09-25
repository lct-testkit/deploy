#!/usr/bin/env python3
"""Сверяет compose/, charts/rtk-crm/ и копии общих конфигов с images.yaml —
единым источником истины (см. `.github/workflows/validate.yml`, джоб `drift`).

Проверки:
  1. compose/docker-compose.yml не содержит литералов образов: каждый `image:`
     — переменная `${<ИМЯ>_IMAGE...}`, и эта переменная порождается
     render_env_images.py (иначе compose снова начнёт жить своей жизнью).
  2. Каждый образ из profiles.core есть в compose; каждый сервис compose с
     образом отображён на images.yaml.
  3. charts/rtk-crm/values.yaml: registry, имена собственных образов и digest'ы
     внешних образов совпадают с images.yaml.
  4. Копии общих конфигов (Caddyfile, realm-crm.json, s3.json, init-keycloak-db.sh)
     в compose/ побайтно совпадают с копиями в charts/rtk-crm/files/ (Caddyfile
     в чарте отличается только upstream'ом api — сравнивается без него) и,
     если задан --backend-dir, с backend/deploy/.

    python scripts/check_drift.py [--backend-dir ../backend]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def load_yaml(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def rendered_vars() -> set[str]:
    out = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "render_env_images.py"), "--allow-missing"],
        capture_output=True,
        text=True,
        check=True,
        cwd=REPO_ROOT,
    ).stdout
    return {line.split("=", 1)[0] for line in out.splitlines() if line and not line.startswith("#")}


def check_compose(images_doc: dict) -> None:
    compose_path = REPO_ROOT / "compose" / "docker-compose.yml"
    doc = load_yaml(compose_path)
    known_vars = rendered_vars()
    used_vars: set[str] = set()

    for svc, spec in (doc.get("services") or {}).items():
        image = spec.get("image", "")
        if not image:
            err(f"compose: сервис {svc!r} без image")
            continue
        m = re.match(r"^\$\{([A-Z0-9_]+_IMAGE)(:?\?[^}]*)?\}$", image)
        if not m:
            err(f"compose: сервис {svc!r} использует литерал образа {image!r} — "
                "ссылки берутся только из <ИМЯ>_IMAGE (images.yaml)")
            continue
        var = m.group(1)
        used_vars.add(var)
        if var not in known_vars:
            err(f"compose: сервис {svc!r} читает {var}, но render_env_images.py её не порождает")

    # Каждый образ core обязан использоваться compose'ом.
    core = set(images_doc.get("profiles", {}).get("core", []))
    services_map = images_doc.get("services", {})
    core_images = {services_map.get(name, name) for name in core}
    for name in core_images:
        var = re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_IMAGE"
        if var not in used_vars:
            err(f"compose: образ {name!r} входит в profiles.core, но {var} нигде не используется")


def check_values(images_doc: dict) -> None:
    registry = images_doc["registry"]
    all_images = images_doc.get("images", {})
    external = images_doc.get("external", {})
    core = set(images_doc.get("profiles", {}).get("core", []))
    own_images = {name for name in all_images if name in core}

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
        else:
            want = all_images[name]
            if spec.get("tag") != want.get("tag") or spec.get("digest") != want.get("digest"):
                err(f"values.yaml: images.{name} tag/digest ({spec.get('tag')!r}/{spec.get('digest')!r}) "
                    f"расходятся с images.yaml ({want.get('tag')!r}/{want.get('digest')!r}) — "
                    "их ведёт бот (update_image_refs.py), руками не правим")

    for name, ext in external.items():
        if name == "local-registry":  # только compose-профиль registry, в чарте не нужен
            continue
        v_spec = values_images.get(name)
        if v_spec is None:
            err(f"values.yaml: нет images.{name} (есть в images.yaml.external)")
            continue
        expected = ext.get("digest", "")
        if expected and v_spec.get("digest", "") != expected:
            err(f"values.yaml: images.{name}.digest={v_spec.get('digest')!r}, "
                f"images.yaml.external.{name}={expected!r}")


def _read(path: Path) -> bytes | None:
    return path.read_bytes().replace(b"\r\n", b"\n") if path.exists() else None


def check_shared_configs(backend_dir: Path | None) -> None:
    compose = REPO_ROOT / "compose"
    chart_files = REPO_ROOT / "charts" / "rtk-crm" / "files"
    shared = {
        "keycloak/realm-crm.json": "realm-crm.json",
        "seaweedfs/s3.json": "s3.json",
        "postgres/init-keycloak-db.sh": "init-keycloak-db.sh",
    }
    for rel, chart_name in shared.items():
        base = _read(compose / rel)
        if base is None:
            err(f"нет compose/{rel}")
            continue
        chart = _read(chart_files / chart_name)
        if chart is not None and chart != base:
            err(f"charts/rtk-crm/files/{chart_name} расходится с compose/{rel}")
        if backend_dir is not None:
            src = _read(backend_dir / "deploy" / rel)
            if src is not None and src != base:
                err(f"compose/{rel} расходится с backend/deploy/{rel} "
                    "(копия должна быть побайтно идентична источнику)")

    if backend_dir is not None:
        src = _read(backend_dir / "deploy" / "Caddyfile")
        base = _read(compose / "Caddyfile")
        if src is not None and base is not None and src != base:
            err("compose/Caddyfile расходится с backend/deploy/Caddyfile")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--backend-dir", type=Path, default=None,
                        help="путь к checkout backend для сверки копий общих конфигов")
    args = parser.parse_args()

    images_doc = load_yaml(REPO_ROOT / "images.yaml")
    check_compose(images_doc)
    check_values(images_doc)
    check_shared_configs(args.backend_dir)

    if errors:
        for e in errors:
            print(f"ERROR {e}", file=sys.stderr)
        print(f"\nрасхождение с images.yaml/источниками: {len(errors)} ошибок", file=sys.stderr)
        return 1

    print("ок: compose, chart и общие конфиги согласованы с images.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
