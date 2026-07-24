#!/usr/bin/env python3
"""
platform-iac-modules bootstrap setup (SoT)

This script is the Source of Truth (SoT) for local bootstrap logic.
Platform-specific wrappers (setup.sh / setup.ps1) should delegate to this script.

Goals:
- Cross-platform (Linux/macOS/Windows)
- Idempotent operations
- Plan / apply modes
- Deterministic and observable output
- Enterprise-friendly error handling and exit codes

Usage examples:
  python scripts/bootstrap/setup.py --plan
  python scripts/bootstrap/setup.py --apply
  python scripts/bootstrap/setup.py --apply --non-interactive
  python scripts/bootstrap/setup.py --apply --strict
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional

# =========================
# Exit Codes (stable contract)
# =========================
EXIT_OK = 0
EXIT_VALIDATION_FAILED = 2
EXIT_BOOTSTRAP_FAILED = 3
EXIT_UNEXPECTED = 99


# =========================
# Helpers
# =========================
def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def run_cmd(
    cmd: List[str],
    cwd: Optional[Path] = None,
    check: bool = False,
    capture_output: bool = True,
    env: Optional[dict] = None,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        check=check,
        text=True,
        capture_output=capture_output,
    )


def which(cmd: str) -> Optional[str]:
    return shutil.which(cmd)


def is_windows() -> bool:
    return platform.system().lower() == "windows"


def is_macos() -> bool:
    return platform.system().lower() == "darwin"


def is_linux() -> bool:
    return platform.system().lower() == "linux"


# =========================
# Domain Model
# =========================
@dataclass
class CheckResult:
    name: str
    passed: bool
    message: str
    severity: str = "error"  # info | warn | error


@dataclass
class ActionResult:
    name: str
    changed: bool
    success: bool
    message: str


@dataclass
class BootstrapContext:
    root_dir: Path
    scripts_dir: Path
    tooling_dir: Path
    mode: str  # plan | apply
    non_interactive: bool
    strict: bool
    verbose: bool
    json_output: bool
    checks: List[CheckResult] = field(default_factory=list)
    actions: List[ActionResult] = field(default_factory=list)

    def add_check(self, result: CheckResult):
        self.checks.append(result)
        if self.verbose:
            status = "PASS" if result.passed else "FAIL"
            print(f"[check:{status}] {result.name}: {result.message}")

    def add_action(self, result: ActionResult):
        self.actions.append(result)
        if self.verbose:
            status = "OK" if result.success else "ERR"
            changed = "changed" if result.changed else "no-change"
            print(f"[action:{status}] {result.name} ({changed}): {result.message}")


# =========================
# Bootstrap Logic
# =========================
REQUIRED_FILES = [
    "go.mod",
    "Taskfile.yml",
    ".pre-commit-config.yaml",
    "tooling/.terraform-version",
]


def validate_repo_layout(ctx: BootstrapContext) -> bool:
    ok = True
    for rel in REQUIRED_FILES:
        p = ctx.root_dir / rel
        exists = p.exists()
        if not exists:
            ok = False
        ctx.add_check(
            CheckResult(
                name=f"repo-layout:{rel}",
                passed=exists,
                message=f"{'found' if exists else 'missing'}: {p}",
                severity="error",
            )
        )
    return ok


def detect_python(ctx: BootstrapContext) -> bool:
    major, minor = sys.version_info.major, sys.version_info.minor
    passed = (major > 3) or (major == 3 and minor >= 10)
    ctx.add_check(
        CheckResult(
            name="python-version",
            passed=passed,
            message=f"detected Python {major}.{minor}; requires >= 3.10",
            severity="error",
        )
    )
    return passed


def detect_platform(ctx: BootstrapContext) -> bool:
    sys_name = platform.system()
    machine = platform.machine()
    ctx.add_check(
        CheckResult(
            name="platform",
            passed=True,
            message=f"{sys_name} / {machine}",
            severity="info",
        )
    )
    return True


def detect_required_tools(ctx: BootstrapContext) -> bool:
    # Minimal hard requirements for bootstrap orchestration
    required = ["git"]
    # Optional but recommended in this repo context
    recommended = ["pre-commit", "terraform", "go"]

    ok = True
    for tool in required:
        path = which(tool)
        passed = path is not None
        if not passed:
            ok = False
        ctx.add_check(
            CheckResult(
                name=f"tool:{tool}",
                passed=passed,
                message=f"{'found at ' + path if path else 'not found in PATH'}",
                severity="error",
            )
        )

    for tool in recommended:
        path = which(tool)
        ctx.add_check(
            CheckResult(
                name=f"tool:{tool}",
                passed=path is not None,
                message=f"{'found at ' + path if path else 'not found (recommended)'}",
                severity="warn",
            )
        )

    return ok


def run_verify_env(ctx: BootstrapContext) -> bool:
    """
    Delegate to scripts/tools/verify-env.py if present.
    Non-zero exit -> check failure (or warning if non-strict).
    """
    script = ctx.root_dir / "scripts" / "tools" / "verify-env.py"
    if not script.exists():
        ctx.add_check(
            CheckResult(
                name="verify-env-script",
                passed=True,
                message="scripts/tools/verify-env.py not found; skipped",
                severity="warn",
            )
        )
        return True

    cp = run_cmd([sys.executable, str(script)], cwd=ctx.root_dir, check=False)
    passed = cp.returncode == 0
    severity = "error" if ctx.strict else "warn"
    ctx.add_check(
        CheckResult(
            name="verify-env",
            passed=passed,
            message=(cp.stdout.strip() or cp.stderr.strip() or f"exit={cp.returncode}"),
            severity=severity,
        )
    )
    return passed or (not ctx.strict)


def apply_precommit(ctx: BootstrapContext) -> ActionResult:
    if which("pre-commit") is None:
        return ActionResult(
            name="pre-commit-install",
            changed=False,
            success=not ctx.strict,
            message="pre-commit not found; skipped",
        )

    cp = run_cmd(["pre-commit", "install"], cwd=ctx.root_dir, check=False)
    success = cp.returncode == 0
    return ActionResult(
        name="pre-commit-install",
        changed=success,
        success=success,
        message=(cp.stdout.strip() or cp.stderr.strip() or f"exit={cp.returncode}"),
    )


def apply_toolchain_install(ctx: BootstrapContext) -> ActionResult:
    script = ctx.root_dir / "scripts" / "tools" / "install-tools.go"
    if not script.exists():
        return ActionResult(
            name="toolchain-install",
            changed=False,
            success=True,
            message="scripts/tools/install-tools.go not found; skipped",
        )

    if which("go") is None:
        return ActionResult(
            name="toolchain-install",
            changed=False,
            success=not ctx.strict,
            message="go not found; cannot run install-tools.go",
        )

    cp = run_cmd(["go", "run", str(script)], cwd=ctx.root_dir, check=False)
    success = cp.returncode == 0
    return ActionResult(
        name="toolchain-install",
        changed=success,
        success=success,
        message=(cp.stdout.strip() or cp.stderr.strip() or f"exit={cp.returncode}"),
    )


def maybe_confirm(ctx: BootstrapContext) -> bool:
    if ctx.non_interactive or ctx.mode != "apply":
        return True
    try:
        answer = input("Proceed with bootstrap apply? [y/N]: ").strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


def summary(ctx: BootstrapContext) -> dict:
    failed_errors = [
        c for c in ctx.checks if (not c.passed and c.severity == "error")
    ]
    failed_warnings = [
        c for c in ctx.checks if (not c.passed and c.severity == "warn")
    ]
    failed_actions = [a for a in ctx.actions if not a.success]

    return {
        "mode": ctx.mode,
        "root_dir": str(ctx.root_dir),
        "checks_total": len(ctx.checks),
        "checks_failed_error": len(failed_errors),
        "checks_failed_warn": len(failed_warnings),
        "actions_total": len(ctx.actions),
        "actions_failed": len(failed_actions),
        "ok": len(failed_errors) == 0 and len(failed_actions) == 0,
    }


def print_summary(ctx: BootstrapContext):
    s = summary(ctx)
    if ctx.json_output:
        payload = {
            "summary": s,
            "checks": [c.__dict__ for c in ctx.checks],
            "actions": [a.__dict__ for a in ctx.actions],
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return

    print("\n=== Bootstrap Summary ===")
    print(f"Mode: {s['mode']}")
    print(f"Root: {s['root_dir']}")
    print(
        f"Checks: total={s['checks_total']} "
        f"errors={s['checks_failed_error']} warns={s['checks_failed_warn']}"
    )
    print(f"Actions: total={s['actions_total']} failed={s['actions_failed']}")
    print(f"Result: {'SUCCESS' if s['ok'] else 'FAILED'}")


def run_plan(ctx: BootstrapContext) -> int:
    validate_repo_layout(ctx)
    detect_python(ctx)
    detect_platform(ctx)
    detect_required_tools(ctx)
    run_verify_env(ctx)

    print_summary(ctx)
    s = summary(ctx)
    return EXIT_OK if s["checks_failed_error"] == 0 else EXIT_VALIDATION_FAILED


def run_apply(ctx: BootstrapContext) -> int:
    preflight_code = run_plan(ctx)
    if preflight_code != EXIT_OK:
        return preflight_code

    if not maybe_confirm(ctx):
        eprint("Apply cancelled by user.")
        return EXIT_BOOTSTRAP_FAILED

    # Apply actions (idempotent)
    for action_fn in (apply_precommit, apply_toolchain_install):
        result = action_fn(ctx)
        ctx.add_action(result)

    print_summary(ctx)
    s = summary(ctx)
    return EXIT_OK if s["ok"] else EXIT_BOOTSTRAP_FAILED


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap local environment for platform-iac-modules (SoT)."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true", help="Run preflight checks only.")
    mode.add_argument("--apply", action="store_true", help="Run checks + apply actions.")
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Disable interactive confirmation prompts.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warning-level checks as hard failures where applicable.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable detailed check/action logs.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print machine-readable JSON summary.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        args = parse_args(argv)

        script_path = Path(__file__).resolve()
        root_dir = script_path.parents[2]  # scripts/bootstrap/setup.py -> repo root

        ctx = BootstrapContext(
            root_dir=root_dir,
            scripts_dir=root_dir / "scripts",
            tooling_dir=root_dir / "tooling",
            mode="apply" if args.apply else "plan",
            non_interactive=args.non_interactive,
            strict=args.strict,
            verbose=args.verbose,
            json_output=args.json_output,
        )

        if ctx.mode == "plan":
            return run_plan(ctx)
        return run_apply(ctx)

    except KeyboardInterrupt:
        eprint("Interrupted by user.")
        return EXIT_BOOTSTRAP_FAILED
    except Exception as exc:  # noqa: BLE001
        eprint(f"Unexpected error: {exc}")
        return EXIT_UNEXPECTED


if __name__ == "__main__":
    raise SystemExit(main())
