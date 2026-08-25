#!/usr/bin/env python3
"""
platform-iac-modules bootstrap setup (SoT)

This script is the Source of Truth (SoT) for local bootstrap logic.
Platform-specific wrappers (setup.sh / setup.ps1) should delegate to this script.

Goals:
- Cross-platform (Linux / macOS / Windows)
- Idempotent operations
- Plan / apply modes
- Deterministic and observable output
- Enterprise-friendly error handling and exit codes

Usage examples:
  python scripts/bootstrap/setup.py --plan
  python scripts/bootstrap/setup.py --apply
  python scripts/bootstrap/setup.py --apply --non-interactive
  python scripts/bootstrap/setup.py --apply --strict
  python scripts/bootstrap/setup.py --apply --non-interactive --strict --json

Environment contract (injected by setup.sh / setup.ps1):
  BOOTSTRAP_WRAPPER_KIND    powershell | bash
  BOOTSTRAP_WRAPPER_OS      windows | linux | macos | bsd | unknown
  BOOTSTRAP_WRAPPER_OS_RAW  raw OS description string
  BOOTSTRAP_WRAPPER_ARCH    x86_64 | arm64 | x86 | <raw>
  BOOTSTRAP_WRAPPER_DISTRO  linux distro id (from /etc/os-release) or ""
  BOOTSTRAP_WRAPPER_KERNEL  kernel / OS version string
  BOOTSTRAP_WRAPPER_WSL     "1" when running under WSL, else "0"
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

# =============================================================================
# Exit Codes (stable contract)
# =============================================================================
EXIT_OK = 0
EXIT_VALIDATION_FAILED = 2
EXIT_BOOTSTRAP_FAILED = 3
EXIT_UNEXPECTED = 99

# =============================================================================
# Helpers
# =============================================================================

def eprint(*args, **kwargs) -> None:
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


def _parse_version(version_str: str) -> Tuple[int, ...]:
    """
    Parse a dotted version string into a tuple of ints for reliable comparison.
    '1.21.5' -> (1, 21, 5); '1.21' -> (1, 21)
    Raises ValueError for an unparseable string.
    """
    parts = version_str.strip().split(".")
    return tuple(int(p) for p in parts)


def _version_ge(actual: str, required: str) -> bool:
    """Return True when actual >= required (numeric dotted comparison)."""
    try:
        return _parse_version(actual) >= _parse_version(required)
    except (ValueError, AttributeError):
        return False


# =============================================================================
# OS Detection
# =============================================================================

_OS_PLATFORM_MAP = {
    "windows": "windows",
    "linux":   "linux",
    "darwin":  "macos",
}

_BOOTSTRAP_WRAPPER_OS_VALID = {"windows", "linux", "macos", "bsd"}


def _normalize_os() -> str:
    """
    Return a normalized OS family string: windows | linux | macos | bsd | unknown.

    Priority:
      1. BOOTSTRAP_WRAPPER_OS injected by setup.sh / setup.ps1 (trusted source)
      2. platform.system() fallback for direct invocations (CI, dev machines
         that do not use the wrapper scripts)
    """
    wrapper_os = os.environ.get("BOOTSTRAP_WRAPPER_OS", "").strip().lower()
    if wrapper_os in _BOOTSTRAP_WRAPPER_OS_VALID:
        return wrapper_os

    sys_name = platform.system().lower()
    return _OS_PLATFORM_MAP.get(sys_name, "unknown")


def _is_wsl() -> bool:
    """True when the wrapper reported WSL=1, or /proc/version contains 'microsoft'."""
    if os.environ.get("BOOTSTRAP_WRAPPER_WSL") == "1":
        return True
    proc_version = Path("/proc/version")
    if proc_version.exists():
        try:
            return bool(re.search(r"microsoft|wsl", proc_version.read_text(), re.I))
        except OSError:
            pass
    return False


# Convenience shorthands used throughout the module
def _os_is_windows() -> bool:
    return _normalize_os() == "windows"


def _os_is_macos() -> bool:
    return _normalize_os() == "macos"


def _os_is_linux() -> bool:
    return _normalize_os() == "linux"


# =============================================================================
# Domain Model
# =============================================================================

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
    mode: str           # plan | apply
    non_interactive: bool
    strict: bool
    verbose: bool
    json_output: bool
    checks: List[CheckResult] = field(default_factory=list)
    actions: List[ActionResult] = field(default_factory=list)

    def add_check(self, result: CheckResult) -> None:
        self.checks.append(result)
        if self.verbose:
            status = "PASS" if result.passed else "FAIL"
            print(f"[check:{status}] {result.name}: {result.message}")

    def add_action(self, result: ActionResult) -> None:
        self.actions.append(result)
        if self.verbose:
            status  = "OK"       if result.success else "ERR"
            changed = "changed"  if result.changed else "no-change"
            print(f"[action:{status}] {result.name} ({changed}): {result.message}")


# =============================================================================
# go.mod Version Reader
# =============================================================================

_GO_MOD_DIRECTIVE_RE = re.compile(
    r"^\s*go\s+(?P<version>\d+\.\d+(?:\.\d+)?)\s*$",
    re.MULTILINE,
)


def _read_go_version_from_gomod(root_dir: Path) -> Optional[str]:
    """
    Extract the `go X.Y[.Z]` directive from go.mod.

    Returns the version string (e.g. '1.21' or '1.21.5'), or None when the
    file is missing or contains no parseable go directive.
    """
    gomod = root_dir / "go.mod"
    if not gomod.exists():
        return None
    try:
        content = gomod.read_text(encoding="utf-8")
    except OSError:
        return None

    match = _GO_MOD_DIRECTIVE_RE.search(content)
    return match.group("version") if match else None


# =============================================================================
# Go Interpreter Utilities
# =============================================================================

def _get_go_version(go_cmd: str) -> Optional[str]:
    """
    Return the `go version` output parsed to 'MAJOR.MINOR[.PATCH]',
    or None when the binary is absent or unusable.

    `go version` emits: 'go version go1.21.5 linux/amd64'
    """
    try:
        cp = run_cmd([go_cmd, "version"], check=False)
        if cp.returncode != 0:
            return None
        # Extract the goX.Y.Z token
        m = re.search(r"go(\d+\.\d+(?:\.\d+)?)", cp.stdout)
        return m.group(1) if m else None
    except (OSError, FileNotFoundError):
        return None


def _find_suitable_go(required_version: str) -> Optional[str]:
    """
    Search PATH candidates for a Go binary whose version >= required_version.
    Returns the command name ('go') when found, else None.
    """
    candidates = [c for c in ("go",) if which(c)]
    for cmd in candidates:
        ver = _get_go_version(cmd)
        if ver and _version_ge(ver, required_version):
            return cmd
        if ver:
            eprint(
                f"[bootstrap] Skipping '{cmd}' (v{ver}); "
                f"requires >= {required_version}"
            )
    return None


# =============================================================================
# Go Installation
# =============================================================================

def _install_go_via_mise(required_version: str) -> Optional[str]:
    if not which("mise"):
        return None
    eprint(f"[bootstrap] Installing Go {required_version} via mise...")
    cp = run_cmd(["mise", "install", f"go@{required_version}"], check=False)
    if cp.returncode != 0:
        return None
    # Ask mise where the shim lives
    cp2 = run_cmd(["mise", "which", "go"], check=False)
    if cp2.returncode == 0:
        go_bin = cp2.stdout.strip()
        if go_bin and Path(go_bin).exists():
            return go_bin
    return which("go") or None


def _install_go_via_asdf(required_version: str) -> Optional[str]:
    if not which("asdf"):
        return None
    eprint(f"[bootstrap] Installing Go {required_version} via asdf...")
    run_cmd(["asdf", "plugin", "add", "golang"], check=False)   # idempotent
    cp = run_cmd(["asdf", "install", "golang", required_version], check=False)
    if cp.returncode == 0:
        return which("go") or None
    return None


def _install_go_native_manager(required_version: str) -> Optional[str]:
    """Fallback to OS-specific package manager."""
    os_fam = _normalize_os()
    if os_fam == "macos" and which("brew"):
        run_cmd(["brew", "install", "go"], check=False)
    elif os_fam == "windows":
        if which("winget"):
            run_cmd(["winget", "install", "--id", "Google.Go", "-e", "--silent"], check=False)
        elif which("choco"):
            run_cmd(["choco", "install", "golang", "-y"], check=False)
    elif os_fam == "linux":
        # Best effort (unlikely to have permissions in non-container contexts)
        if which("apt-get"):
            run_cmd(["sudo", "apt-get", "update"], check=False)
            run_cmd(["sudo", "apt-get", "install", "-y", "golang"], check=False)
    return which("go") or None


# =============================================================================
# Bootstrap Check & Action Functions
# =============================================================================

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
    os_fam   = _normalize_os()
    raw_os   = os.environ.get("BOOTSTRAP_WRAPPER_OS_RAW") or platform.system()
    arch     = os.environ.get("BOOTSTRAP_WRAPPER_ARCH")   or platform.machine()
    is_wsl_v = _is_wsl()

    msg = f"os={os_fam} arch={arch} raw='{raw_os}' wsl={is_wsl_v}"
    ctx.add_check(CheckResult(name="platform", passed=True, message=msg, severity="info"))
    return True


def check_go_installation(ctx: BootstrapContext) -> bool:
    required_ver = _read_go_version_from_gomod(ctx.root_dir)
    if not required_ver:
        ctx.add_check(
            CheckResult(
                name="go-pin",
                passed=False,
                message="could not find 'go <version>' in go.mod",
                severity="warn",
            )
        )
        required_ver = "1.18"  # generic fallback

    current_cmd = _find_suitable_go(required_ver)
    current_ver = _get_go_version(current_cmd) if current_cmd else None

    passed = current_ver is not None
    ctx.add_check(
        CheckResult(
            name="tool:go",
            passed=passed,
            message=(
                f"detected v{current_ver} at '{current_cmd}'" if passed
                else f"not found in PATH (requires >= {required_ver})"
            ),
            severity="error",
        )
    )
    return passed


def detect_required_tools(ctx: BootstrapContext) -> bool:
    # Go is handled separately by check_go_installation + ensure_go_ready
    required = ["git"]
    recommended = ["pre-commit", "terraform", "task"]

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
    script = ctx.root_dir / "scripts" / "tools" / "verify-env.py"
    if not script.exists():
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


# =============================================================================
# Apply Actions
# =============================================================================

def ensure_go_ready(ctx: BootstrapContext) -> ActionResult:
    """
    Ensures Go satisfies the pin. Installs it if missing during 'apply' mode.
    """
    required_ver = _read_go_version_from_gomod(ctx.root_dir) or "1.18"
    cmd = _find_suitable_go(required_ver)
    if cmd:
        return ActionResult(
            name="go-ensure",
            changed=False,
            success=True,
            message=f"Go v{_get_go_version(cmd)} already satisfied",
        )

    # Missing or too old -> install
    if ctx.non_interactive is False:
        # Extra safety check in interactive mode
        eprint(f"[bootstrap] Go >= {required_ver} is required but missing.")

    new_cmd = None
    for install_fn in (_install_go_via_mise, _install_go_via_asdf, _install_go_native_manager):
        new_cmd = install_fn(required_ver)
        if new_cmd:
            break

    if new_cmd:
        ver = _get_go_version(new_cmd)
        return ActionResult(
            name="go-ensure",
            changed=True,
            success=True,
            message=f"Installed Go v{ver} via {install_fn.__name__}",
        )

    return ActionResult(
        name="go-ensure",
        changed=False,
        success=False,
        message=f"Failed to install Go >= {required_ver}",
    )


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
    # 1. Determine the platform-specific installer script
    os_fam = _normalize_os()
    script_name = "install-tools-windows.go" if os_fam == "windows" else "install-tools-posix.go"
    script_path = ctx.root_dir / "scripts" / "tools" / script_name

    if not script_path.exists():
        return ActionResult(
            name="toolchain-install",
            changed=False,
            success=False,
            message=f"Installer script missing: {script_path}",
        )

    # 2. Check Go availability (sanity check; ensure_go_ready should have run)
    go_cmd = which("go")
    if not go_cmd:
        return ActionResult(
            name="toolchain-install",
            changed=False,
            success=not ctx.strict,
            message="go binary not found; cannot run toolchain installer",
        )

    # 3. Execution
    eprint(f"[bootstrap] Running toolchain installer: {script_name}...")
    cp = run_cmd([go_cmd, "run", str(script_path)], cwd=ctx.root_dir, check=False)
    success = cp.returncode == 0

    return ActionResult(
        name="toolchain-install",
        changed=success,
        success=success,
        message=(cp.stdout.strip() or cp.stderr.strip() or f"exit={cp.returncode}"),
    )


# =============================================================================
# Lifecycle (Plan / Apply)
# =============================================================================

def maybe_confirm(ctx: BootstrapContext) -> bool:
    if ctx.non_interactive or ctx.mode != "apply":
        return True
    try:
        answer = input("\nProceed with bootstrap apply? [y/N]: ").strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


def summary(ctx: BootstrapContext) -> dict:
    failed_errors = [c for c in ctx.checks if (not c.passed and c.severity == "error")]
    failed_warns  = [c for c in ctx.checks if (not c.passed and c.severity == "warn")]
    failed_acts   = [a for a in ctx.actions if not a.success]

    return {
        "mode": ctx.mode,
        "root_dir": str(ctx.root_dir),
        "checks_total": len(ctx.checks),
        "checks_failed_error": len(failed_errors),
        "checks_failed_warn": len(failed_warns),
        "actions_total": len(ctx.actions),
        "actions_failed": len(failed_acts),
        "ok": len(failed_errors) == 0 and len(failed_acts) == 0,
    }


def print_summary(ctx: BootstrapContext) -> None:
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
    print(f"Mode:    {s['mode']}")
    print(f"Root:    {s['root_dir']}")
    print(f"Checks:  total={s['checks_total']} errors={s['checks_failed_error']} warns={s['checks_failed_warn']}")
    print(f"Actions: total={s['actions_total']} failed={s['actions_failed']}")
    print(f"Result:  {'SUCCESS' if s['ok'] else 'FAILED'}")


def run_plan(ctx: BootstrapContext) -> int:
    # Validations / Discoveries
    validate_repo_layout(ctx)
    detect_python(ctx)
    detect_platform(ctx)
    check_go_installation(ctx)
    detect_required_tools(ctx)
    run_verify_env(ctx)

    print_summary(ctx)
    s = summary(ctx)
    return EXIT_OK if s["checks_failed_error"] == 0 else EXIT_VALIDATION_FAILED


def run_apply(ctx: BootstrapContext) -> int:
    # 1. Preflight (Plan)
    preflight_code = run_plan(ctx)
    if preflight_code != EXIT_OK:
        return preflight_code

    # 2. Interaction
    if not maybe_confirm(ctx):
        eprint("\nApply cancelled by user.")
        return EXIT_BOOTSTRAP_FAILED

    # 3. Actions (Deterministic sequence)
    #    Go MUST be first because toolchain install relies on it.
    actions = [
        ensure_go_ready,
        apply_precommit,
        apply_toolchain_install,
    ]

    for action_fn in actions:
        result = action_fn(ctx)
        ctx.add_action(result)
        # If a critical action (like Go installation) fails, stop immediately
        if not result.success:
            eprint(f"[bootstrap] Critical action failed: {result.name}")
            break

    print_summary(ctx)
    s = summary(ctx)
    return EXIT_OK if s["ok"] else EXIT_BOOTSTRAP_FAILED


# =============================================================================
# CLI Entrypoint
# =============================================================================

def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap local environment for platform-iac-modules (SoT)."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan",  action="store_true", help="Run preflight checks only.")
    mode.add_argument("--apply", action="store_true", help="Run checks + apply actions.")

    parser.add_argument("--non-interactive", action="store_true", help="Disable prompts.")
    parser.add_argument("--strict",  action="store_true", help="Warnings become errors.")
    parser.add_argument("--verbose", action="store_true", help="Log detailed traces.")
    parser.add_argument("--json",    action="store_true", dest="json_output", help="Output JSON summary.")

    return parser.parse_args(argv)


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        args = parse_args(argv)

        script_path = Path(__file__).resolve()
        # Expectation: repo/scripts/bootstrap/setup.py -> parents[2] is repo root
        root_dir = script_path.parents[2]

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
        eprint("\nInterrupted by user.")
        return EXIT_BOOTSTRAP_FAILED
    except Exception as exc:
        eprint(f"\nUnexpected error: {exc}")
        if "--verbose" in sys.argv:
            import traceback
            traceback.print_exc()
        return EXIT_UNEXPECTED


if __name__ == "__main__":
    raise SystemExit(main())
