#!/usr/bin/env python3
"""
Build a GitHub Actions matrix for changed Terraform modules.

Expected output JSON format:
{
  "include": [
    { "name": "kms", "path": "modules/kms" },
    { "name": "scp", "path": "modules/scp" }
  ]
}
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from pathlib import Path
from typing import Iterable, List, Set

MODULE_DIR_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


class MatrixBuildError(Exception):
    """Raised when matrix generation fails due to invalid inputs."""


def configure_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(message)s",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build module test matrix from changed module paths."
    )
    parser.add_argument(
        "--mode",
        choices=["build", "print-env"],
        default="build",
        help="Operation mode.",
    )
    parser.add_argument(
        "--modules-root",
        required=False,
        help="Root directory containing module folders (e.g. modules).",
    )
    parser.add_argument(
        "--changes-file",
        required=False,
        help="JSON file containing changed module paths.",
    )
    parser.add_argument(
        "--out",
        required=False,
        help="Output JSON file path for matrix.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        default=False,
        help="Fail if a changed path is invalid or does not exist under modules-root.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        default=False,
        help="Enable debug logging.",
    )
    return parser.parse_args()


def normalize_posix_path(raw: str) -> str:
    # Normalize separators for cross-platform compatibility (Windows/Linux/macOS runners)
    cleaned = raw.strip().replace("\\", "/")
    while "//" in cleaned:
        cleaned = cleaned.replace("//", "/")
    return cleaned.strip("/")


def load_changes(changes_file: Path) -> List[str]:
    if not changes_file.is_file():
        raise MatrixBuildError(f"changes-file not found: {changes_file}")

    try:
        payload = json.loads(changes_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise MatrixBuildError(f"Invalid JSON in changes-file: {exc}") from exc

    if isinstance(payload, list):
        items = payload
    elif isinstance(payload, dict):
        # Support common shapes for forward/backward compatibility
        if "modules" in payload and isinstance(payload["modules"], list):
            items = payload["modules"]
        elif "changed_modules" in payload and isinstance(payload["changed_modules"], list):
            items = payload["changed_modules"]
        elif "include" in payload and isinstance(payload["include"], list):
            # tolerate matrix-like input to reprocess
            items = [entry.get("path", "") for entry in payload["include"] if isinstance(entry, dict)]
        else:
            raise MatrixBuildError(
                "Unsupported changes-file JSON structure. Expected list or dict with "
                "'modules'/'changed_modules'/'include'."
            )
    else:
        raise MatrixBuildError("Unsupported changes-file JSON type; expected list or object.")

    invalid_non_string = [x for x in items if not isinstance(x, str)]
    if invalid_non_string:
        raise MatrixBuildError("changes-file contains non-string items.")

    return items


def discover_modules(modules_root: Path) -> Set[str]:
    if not modules_root.is_dir():
        raise MatrixBuildError(f"modules-root is not a directory: {modules_root}")

    discovered: Set[str] = set()
    for child in modules_root.iterdir():
        if child.is_dir() and MODULE_DIR_PATTERN.match(child.name):
            discovered.add(f"{modules_root.name}/{child.name}")
    return discovered


def filter_changed_modules(
    raw_changes: Iterable[str],
    modules_root: Path,
    strict: bool,
) -> List[str]:
    valid_modules = discover_modules(modules_root)
    selected: Set[str] = set()

    for raw in raw_changes:
        norm = normalize_posix_path(raw)
        if not norm:
            continue

        # Accept either:
        # - modules/<name>
        # - modules/<name>/<anything>  -> collapse to modules/<name>
        parts = norm.split("/")
        if len(parts) < 2:
            msg = f"Ignoring non-module path: {raw}"
            if strict:
                raise MatrixBuildError(msg)
            logging.warning(msg)
            continue

        if parts[0] != modules_root.name:
            msg = f"Ignoring path outside modules root '{modules_root.name}': {raw}"
            if strict:
                raise MatrixBuildError(msg)
            logging.warning(msg)
            continue

        module_name = parts[1]
        if not MODULE_DIR_PATTERN.match(module_name):
            msg = f"Invalid module name in changed path: {raw}"
            if strict:
                raise MatrixBuildError(msg)
            logging.warning(msg)
            continue

        module_path = f"{modules_root.name}/{module_name}"
        if module_path not in valid_modules:
            msg = f"Changed module does not exist on disk: {module_path} (from {raw})"
            if strict:
                raise MatrixBuildError(msg)
            logging.warning(msg)
            continue

        selected.add(module_path)

    # Deterministic order for stable CI diffs/cache behavior
    return sorted(selected)


def to_matrix(module_paths: Iterable[str]) -> dict:
    include = []
    for module_path in module_paths:
        name = module_path.split("/")[-1]
        include.append({"name": name, "path": module_path})
    return {"include": include}


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp_path, path)


def print_env() -> int:
    import platform
    info = {
        "os": platform.system().lower(),
        "arch": platform.machine().lower(),
        "python": platform.python_version(),
    }
    for key, value in info.items():
        print(f"{key}={value}")
    return 0


def main() -> int:
    args = parse_args()
    configure_logging(args.verbose)

    if args.mode == "print-env":
        return print_env()

    missing = [f for f, v in [("--modules-root", args.modules_root), ("--changes-file", args.changes_file), ("--out", args.out)] if not v]
    if missing:
        logging.error("the following arguments are required: %s", ", ".join(missing))
        return 2

    try:
        modules_root = Path(args.modules_root).resolve()
        changes_file = Path(args.changes_file).resolve()
        out_file = Path(args.out).resolve()

        logging.debug("modules_root=%s", modules_root)
        logging.debug("changes_file=%s", changes_file)
        logging.debug("out=%s", out_file)
        logging.debug("strict=%s", args.strict)

        raw_changes = load_changes(changes_file)
        module_paths = filter_changed_modules(
            raw_changes=raw_changes,
            modules_root=modules_root,
            strict=args.strict,
        )
        matrix = to_matrix(module_paths)

        atomic_write_json(out_file, matrix)
        logging.info("Matrix generated: %d module(s)", len(matrix["include"]))
        return 0

    except MatrixBuildError as exc:
        logging.error("Matrix build failed: %s", exc)
        return 2
    except Exception:
        logging.exception("Unexpected failure while building matrix")
        return 1


if __name__ == "__main__":
    sys.exit(main())
