#!/usr/bin/env python3
"""Catalog-driven smoke tests for platform-iac-modules.

Runs a fast, no-AWS-credentials validation pass over every module declared in
``catalog/modules.yaml``. Provider installation may still require access to
the Terraform registry. For each module the following checks
are executed, in order:

    1. terraform fmt   -check -recursive
    2. terraform init  -backend=false -input=false
    3. terraform validate
    4. tflint          --config tooling/.tflint.hcl   (unless --skip-lint)

This module is the single source of truth (SoT) for the smoke-test contract;
``run-smoke-tests.sh`` and ``run-smoke-tests.ps1`` are thin wrappers that only
resolve a Python 3 interpreter and forward their arguments here unchanged.

The catalog is authoritative. A missing or malformed catalog is an error by
default so a stale catalog cannot silently hide a module. Directory discovery
is available only through the explicit ``--allow-directory-fallback`` recovery
flag.

Exit codes:
    0  all selected modules passed every check
    1  at least one check failed
    2  internal error (unreadable/empty catalog, missing required tool, bad usage)

Usage:
    python3 tests/smoke/run-smoke-tests.py
    python3 tests/smoke/run-smoke-tests.py --module kms --skip-lint
    python3 tests/smoke/run-smoke-tests.py --root . --verbose
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence

LOG = logging.getLogger("smoke")

# Kept identical to scripts/ci/build-matrix.py (MODULE_DIR_PATTERN) so that
# catalog-based and directory-based discovery agree on valid module names.
MODULE_DIR_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")

# Exit codes (see module docstring).
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INTERNAL = 2
DEFAULT_COMMAND_TIMEOUT_SECONDS = 900

# ANSI styling, auto-disabled when not writing to a TTY or when NO_COLOR is set.
_COLOR_ENABLED = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code: str, text: str) -> str:
    """Wrap ``text`` in an ANSI color when color output is enabled."""
    if not _COLOR_ENABLED:
        return text
    return f"\033[{code}m{text}\033[0m"


def green(text: str) -> str:
    return _c("32", text)


def red(text: str) -> str:
    return _c("31", text)


def yellow(text: str) -> str:
    return _c("33", text)


def bold(text: str) -> str:
    return _c("1", text)


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Module:
    """A single module under test."""

    name: str
    path: Path


@dataclass
class CheckResult:
    """Outcome of one command for one module."""

    step: str
    passed: bool
    skipped: bool = False
    duration_s: float = 0.0
    detail: str = ""


@dataclass
class ModuleResult:
    """Aggregated result for a single module across all steps."""

    module: Module
    checks: List[CheckResult] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return all(c.passed for c in self.checks if not c.skipped)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(message)s",
        stream=sys.stderr,
    )


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="run-smoke-tests.py",
        description=(
            "Catalog-driven Terraform smoke tests without requiring AWS "
            "credentials."
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=_default_repo_root(),
        help="Repository root (default: inferred from this script's location).",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=None,
        help="Path to modules catalog (default: <root>/catalog/modules.yaml).",
    )
    parser.add_argument(
        "--modules-root",
        type=Path,
        default=None,
        help="Expected modules directory (default: <root>/modules).",
    )
    parser.add_argument(
        "--allow-directory-fallback",
        action="store_true",
        default=False,
        help="Allow directory discovery only when the catalog is unavailable "
        "or PyYAML is not installed.",
    )
    parser.add_argument(
        "--module",
        action="append",
        dest="modules",
        default=None,
        metavar="NAME",
        help="Limit the run to this module. Repeatable.",
    )
    parser.add_argument(
        "--skip-lint",
        action="store_true",
        default=False,
        help="Skip the tflint step.",
    )
    parser.add_argument(
        "--tflint-config",
        type=Path,
        default=None,
        help="tflint config file (default: <root>/tooling/.tflint.hcl).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        default=False,
        help="Enable debug logging and stream command output.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_COMMAND_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help=(
            "Per-command timeout in seconds "
            f"(default: {DEFAULT_COMMAND_TIMEOUT_SECONDS})."
        ),
    )
    return parser.parse_args(argv)


def _default_repo_root() -> Path:
    # tests/smoke/run-smoke-tests.py -> repo root is two levels up.
    return Path(__file__).resolve().parents[2]


# --------------------------------------------------------------------------- #
# Module discovery
# --------------------------------------------------------------------------- #
def load_modules(
    root: Path,
    catalog_path: Path,
    modules_root: Path,
    *,
    allow_directory_fallback: bool,
) -> List[Module]:
    """Resolve and validate the catalog-defined module list."""
    if catalog_path.is_file():
        try:
            modules = _load_from_catalog(root, catalog_path, modules_root)
        except SmokeError:
            if not allow_directory_fallback:
                raise
            LOG.warning(
                "%s catalog validation failed; using explicitly requested "
                "directory fallback under %s",
                yellow("warning:"),
                modules_root,
            )
        else:
            LOG.debug("Loaded %d module(s) from catalog %s", len(modules), catalog_path)
            return modules
    elif not allow_directory_fallback:
        raise SmokeError(f"catalog not found: {catalog_path}")
    else:
        LOG.warning(
            "%s catalog not found; using explicitly requested directory fallback",
            yellow("warning:"),
        )
    return _discover_from_dirs(root, modules_root)


def _load_from_catalog(
    root: Path,
    catalog_path: Path,
    modules_root: Path,
) -> List[Module]:
    """Parse and validate the project catalog with PyYAML."""
    try:
        import yaml  # type: ignore
    except ImportError:
        raise SmokeError(
            "PyYAML is required to read catalog/modules.yaml; install the "
            "repository Python tooling or use --allow-directory-fallback"
        ) from None

    try:
        data = yaml.safe_load(catalog_path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:  # type: ignore[attr-defined]
        raise SmokeError(f"failed to read catalog {catalog_path}: {exc}") from exc

    if not isinstance(data, dict) or "modules" not in data:
        raise SmokeError(f"catalog {catalog_path} missing top-level 'modules' key")

    schema_version = data.get("schema_version")
    if schema_version != 1:
        raise SmokeError(
            f"unsupported catalog schema_version {schema_version!r}; expected 1"
        )

    entries = data.get("modules") or []
    if not isinstance(entries, list) or not entries:
        raise SmokeError(f"catalog {catalog_path} declares no modules")

    modules_root = modules_root.resolve()
    modules: List[Module] = []
    seen_names: set[str] = set()
    seen_paths: set[Path] = set()

    for entry in entries:
        if not isinstance(entry, dict):
            raise SmokeError(f"invalid module entry in catalog: {entry!r}")
        raw_name = entry.get("name")
        raw_path = entry.get("path")
        if not isinstance(raw_name, str) or not isinstance(raw_path, str):
            raise SmokeError(f"module entry missing name/path: {entry!r}")
        name = raw_name.strip()
        rel_path = raw_path.strip().replace("\\", "/")
        if not name or not rel_path:
            raise SmokeError(f"module entry missing name/path: {entry!r}")
        if not MODULE_DIR_PATTERN.match(name):
            raise SmokeError(f"invalid module name {name!r} (must match {MODULE_DIR_PATTERN.pattern})")
        if name in seen_names:
            raise SmokeError(f"duplicate module name in catalog: {name}")

        module_path = (root / rel_path).resolve()
        if module_path.parent != modules_root or module_path.name != name:
            raise SmokeError(
                f"module {name!r} must map directly to {modules_root} "
                f"with matching name; got {module_path}"
            )
        if module_path in seen_paths:
            raise SmokeError(f"duplicate module path in catalog: {module_path}")
        if not module_path.is_dir():
            raise SmokeError(f"module path does not exist: {module_path}")

        required_files = ("main.tf", "versions.tf", "variables.tf", "outputs.tf")
        missing = [file for file in required_files if not (module_path / file).is_file()]
        if missing:
            raise SmokeError(
                f"module {name!r} is missing required Terraform files: "
                f"{', '.join(missing)}"
            )

        modules.append(Module(name=name, path=module_path))
        seen_names.add(name)
        seen_paths.add(module_path)

    modules.sort(key=lambda m: m.name)
    return modules


def _discover_from_dirs(root: Path, modules_root: Path) -> List[Module]:
    if not modules_root.is_dir():
        raise SmokeError(f"modules root not found: {modules_root}")
    modules: List[Module] = []
    for child in sorted(modules_root.iterdir(), key=lambda p: p.name):
        if not child.is_dir() or not MODULE_DIR_PATTERN.match(child.name):
            continue
        if any(child.glob("*.tf")):
            modules.append(Module(name=child.name, path=child.resolve()))
    if not modules:
        raise SmokeError(f"no modules discovered under {modules_root}")
    return modules


def select_modules(modules: List[Module], wanted: Optional[List[str]]) -> List[Module]:
    if not wanted:
        return modules
    by_name: Dict[str, Module] = {m.name: m for m in modules}
    normalized = [name.strip() for name in wanted if name.strip()]
    missing = [name for name in normalized if name not in by_name]
    if missing:
        available = ", ".join(sorted(by_name)) or "<none>"
        raise SmokeError(
            f"unknown module(s): {', '.join(missing)}. Available: {available}"
        )
    # Preserve the caller-provided order, de-duplicated.
    seen: set[str] = set()
    selected: List[Module] = []
    for name in normalized:
        if name not in seen:
            selected.append(by_name[name])
            seen.add(name)
    if not selected:
        raise SmokeError("--module requires at least one non-empty module name")
    return selected


# --------------------------------------------------------------------------- #
# Command execution
# --------------------------------------------------------------------------- #
def _base_env() -> Dict[str, str]:
    env = os.environ.copy()
    # Mirrors Taskfile.yml so Terraform and related tools behave non-interactively.
    env["TF_IN_AUTOMATION"] = "true"
    env["TF_INPUT"] = "false"
    env.setdefault("CHECKPOINT_DISABLE", "1")
    env.setdefault("PYTHONUTF8", "1")
    env.setdefault("PYTHONIOENCODING", "utf-8")
    return env


def run_command(
    cmd: Sequence[str],
    cwd: Path,
    *,
    stream: bool,
    timeout: int,
) -> CheckResult:
    """Run a command, capturing (or streaming) output.

    Returns a CheckResult; never raises for a non-zero exit status.
    """
    label = " ".join(cmd)
    LOG.debug("→ %s (cwd=%s)", label, cwd)
    start = time.monotonic()
    try:
        if stream:
            proc = subprocess.run(
                cmd,
                cwd=str(cwd),
                env=_base_env(),
                stdin=subprocess.DEVNULL,
                timeout=timeout,
                check=False,
            )
            output = ""
        else:
            proc = subprocess.run(
                cmd,
                cwd=str(cwd),
                env=_base_env(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
                check=False,
            )
            output = proc.stdout or ""
    except subprocess.TimeoutExpired:
        return CheckResult(
            step=label,
            passed=False,
            duration_s=time.monotonic() - start,
            detail=f"command timed out after {timeout}s",
        )
    except OSError as exc:
        return CheckResult(
            step=label, passed=False, duration_s=time.monotonic() - start, detail=str(exc)
        )
    duration = time.monotonic() - start
    passed = proc.returncode == 0
    detail = "" if passed else output.strip()
    return CheckResult(step=label, passed=passed, duration_s=duration, detail=detail)


def resolve_tool(name: str) -> str:
    """Return the absolute path to a required tool or raise SmokeError."""
    resolved = shutil.which(name)
    if resolved is None:
        raise SmokeError(f"required tool not found on PATH: {name}")
    return resolved


# --------------------------------------------------------------------------- #
# Smoke run
# --------------------------------------------------------------------------- #
def smoke_module(
    module: Module,
    *,
    terraform: str,
    tflint: Optional[str],
    tflint_config: Path,
    stream: bool,
    timeout: int,
) -> ModuleResult:
    result = ModuleResult(module=module)

    steps: List[Sequence[str]] = [
        [terraform, "fmt", "-check", "-recursive"],
        [terraform, "init", "-backend=false", "-input=false", "-no-color"],
        [terraform, "validate", "-no-color"],
    ]

    for cmd in steps:
        check = run_command(cmd, cwd=module.path, stream=stream, timeout=timeout)
        result.checks.append(check)
        if not check.passed:
            # Stop at the first failing Terraform step for this module; later
            # steps depend on a successful init/validate.
            LOG.debug("stopping module %s after failed step: %s", module.name, check.step)
            return result

    if tflint is not None:
        cmd = [tflint, f"--config={tflint_config}", "--no-color", "--chdir", str(module.path)]
        result.checks.append(
            run_command(cmd, cwd=module.path, stream=stream, timeout=timeout)
        )
    else:
        result.checks.append(
            CheckResult(step="tflint", passed=True, skipped=True, detail="skipped")
        )

    return result


def print_report(results: List[ModuleResult]) -> None:
    print()
    print(bold("Smoke test summary"))
    print("-" * 60)
    name_width = max((len(r.module.name) for r in results), default=6)
    for r in results:
        status = green("PASS") if r.passed else red("FAIL")
        total = sum(c.duration_s for c in r.checks)
        print(f"  {r.module.name.ljust(name_width)}  {status}  ({total:5.1f}s)")
        for c in r.checks:
            if c.skipped:
                print(f"      - {c.step}: {yellow('skipped')}")
            elif not c.passed:
                print(f"      - {red('failed')}: {c.step}")
                if c.detail:
                    for line in c.detail.splitlines():
                        print(f"          {line}")
    print("-" * 60)
    passed = sum(1 for r in results if r.passed)
    failed = len(results) - passed
    summary = f"{passed} passed, {failed} failed, {len(results)} total"
    print(bold(green(summary)) if failed == 0 else bold(red(summary)))


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
class SmokeError(Exception):
    """Raised for unrecoverable setup/usage errors (maps to exit code 2)."""


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    configure_logging(args.verbose)

    try:
        if args.timeout <= 0:
            raise SmokeError("--timeout must be greater than zero")
        root: Path = args.root.resolve()
        if not root.is_dir():
            raise SmokeError(f"repository root not found: {root}")

        catalog_path = (args.catalog or root / "catalog" / "modules.yaml").resolve()
        modules_root = (args.modules_root or root / "modules").resolve()
        tflint_config = (args.tflint_config or root / "tooling" / ".tflint.hcl").resolve()

        terraform = resolve_tool("terraform")
        tflint: Optional[str] = None
        if not args.skip_lint:
            tflint = resolve_tool("tflint")
            if not tflint_config.is_file():
                raise SmokeError(f"tflint config not found: {tflint_config}")
            # Match Taskfile.yml: plugin initialization is a required gate.
            _init = run_command(
                [tflint, f"--config={tflint_config}", "--init"],
                cwd=root,
                stream=args.verbose,
                timeout=args.timeout,
            )
            if not _init.passed:
                raise SmokeError(
                    f"tflint plugin initialization failed: {_init.detail or _init.step}"
                )

        modules = select_modules(
            load_modules(
                root,
                catalog_path,
                modules_root,
                allow_directory_fallback=args.allow_directory_fallback,
            ),
            args.modules,
        )
    except SmokeError as exc:
        LOG.error("%s %s", red("error:"), exc)
        return EXIT_INTERNAL

    LOG.info(
        "Running smoke tests for %d module(s)%s",
        len(modules),
        "" if not args.skip_lint else " (lint skipped)",
    )

    results: List[ModuleResult] = []
    for module in modules:
        LOG.info("• %s", bold(module.name))
        results.append(
            smoke_module(
                module,
                terraform=terraform,
                tflint=tflint,
                tflint_config=tflint_config,
                stream=args.verbose,
                timeout=args.timeout,
            )
        )

    print_report(results)
    return EXIT_OK if all(r.passed for r in results) else EXIT_FAILED


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(red("\nInterrupted."), file=sys.stderr)
        sys.exit(130)
