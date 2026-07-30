#!/usr/bin/env python3
"""
verify-env.py

Production-ready environment verification for platform-iac-modules repository.

Validates:
- Repository shape and required files
- Runtime availability (python, git, go, terraform, ...)
- .tool-versions and .terraform-version consistency
- Optional strict mode to fail on any warning/error

Usage:
  python3 scripts/tools/verify-env.py --root . --strict
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# -----------------------------
# Constants / Patterns
# -----------------------------
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
GO_VERSION_RE = re.compile(r"^go\s+(\d+\.\d+)(?:\.\d+)?\s*$")
TOOL_VERSIONS_LINE_RE = re.compile(r"^([A-Za-z0-9._-]+)\s+([^\s#]+)")

DEFAULT_CMD_TIMEOUT = 10

REQUIRED_FILES = [
    "go.mod",
    "tooling/.terraform-version",
    "tooling/.tool-versions",
    "scripts/tools/verify-env.py",
]

# Commands expected in PATH (minimum baseline)
REQUIRED_COMMANDS = [
    "git",
    "go",
    "terraform",
    "python3",   # on Windows this may fail; handled with alias fallback
]

# map tool-versions key -> executable candidates for PATH lookup
TOOL_EXECUTABLE_MAP = {
    "terraform": ["terraform"],
    "tflint": ["tflint"],
    "trivy": ["trivy", "trivy.exe"],
    "golangci-lint": ["golangci-lint", "golangci-lint.exe"],
}


@dataclass
class CheckMessage:
    level: str  # PASS, WARN, FAIL
    code: str
    message: str


@dataclass
class VerificationReport:
    messages: List[CheckMessage] = field(default_factory=list)

    def add_pass(self, code: str, message: str) -> None:
        self.messages.append(CheckMessage("PASS", code, message))

    def add_warn(self, code: str, message: str) -> None:
        self.messages.append(CheckMessage("WARN", code, message))

    def add_fail(self, code: str, message: str) -> None:
        self.messages.append(CheckMessage("FAIL", code, message))

    @property
    def has_failures(self) -> bool:
        return any(m.level == "FAIL" for m in self.messages)

    @property
    def has_warnings(self) -> bool:
        return any(m.level == "WARN" for m in self.messages)

    def print(self) -> None:
        symbols = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌"}
        for m in self.messages:
            print(f"{symbols.get(m.level, '-')} [{m.level}] {m.code}: {m.message}")

        total = len(self.messages)
        fails = sum(1 for m in self.messages if m.level == "FAIL")
        warns = sum(1 for m in self.messages if m.level == "WARN")
        passes = sum(1 for m in self.messages if m.level == "PASS")
        print("\n--- Summary ---")
        print(f"Total: {total} | PASS: {passes} | WARN: {warns} | FAIL: {fails}")


# -----------------------------
# Utility Functions
# -----------------------------
def run_command(cmd: List[str], timeout: int = DEFAULT_CMD_TIMEOUT) -> Tuple[int, str, str]:
    """
    Run an external command safely for CI/local use.

    Hardening:
    - stdin=DEVNULL avoids tools hanging on non-TTY input
    - process group (POSIX) enables reliable timeout kill of children
    - explicit handling of timeout / not-found / interrupt / OS errors
    """
    if not cmd:
        return 2, "", "Empty command"
    try:
        popen_kwargs = {
            "args": cmd,
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "text": True,
            "check": False,
            "timeout": timeout,
        }

        if os.name == "posix":
            popen_kwargs["start_new_session"] = True

        proc = subprocess.run(**popen_kwargs)
        stdout = (proc.stdout or "").strip()
        stderr = (proc.stderr or "").strip()
        return proc.returncode, stdout, stderr
    except FileNotFoundError:
        return 127, "", f"Command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"Command timed out after {timeout}s: {' '.join(cmd)}"
    except OSError as exc:
        return 1, "", f"OS error while running {' '.join(cmd)}: {exc}"
    except Exception as exc:
        return 1, "", f"Unexpected error while running {' '.join(cmd)}: {exc}"


def detect_python_command() -> str:
    # prefer python3, fallback python
    if shutil.which("python3"):
        return "python3"
    if shutil.which("python"):
        return "python"
    return "python3"


def read_text_file(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8").strip()
    except Exception:
        return None


def parse_tool_versions(path: Path) -> Dict[str, str]:
    tools: Dict[str, str] = {}
    content = read_text_file(path)
    if content is None:
        return tools
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = TOOL_VERSIONS_LINE_RE.match(line)
        if not m:
            continue
        tool, version = m.group(1), m.group(2)
        tools[tool] = version
    return tools


def normalize_version(raw: str) -> str:
    # remove leading "v" and metadata not required for comparison
    return raw.strip().lstrip("v")


def parse_terraform_version_output(output: str) -> Optional[str]:
    # e.g. Terraform v1.8.5
    for line in output.splitlines():
        line = line.strip()
        if line.lower().startswith("terraform "):
            parts = line.split()
            if len(parts) >= 2:
                return normalize_version(parts[1])
    return None


def parse_tflint_version_output(output: str) -> Optional[str]:
    # e.g. TFLint version 0.52.0
    m = re.search(r"(?i)\bversion\s+v?(\d+\.\d+\.\d+)", output)
    return m.group(1) if m else None


def parse_trivy_version_output(output: str) -> Optional[str]:
    # Handles both `trivy --version` multiline output and `trivy version`
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.lower().startswith("version:"):
            candidate = normalize_version(line.split(":", 1)[1].strip())
            if SEMVER_RE.match(candidate):
                return candidate
        if line.lower().startswith("trivy version"):
            parts = line.split()
            for token in reversed(parts):
                token_norm = normalize_version(token)
                if SEMVER_RE.match(token_norm):
                    return token_norm
    m = re.search(r"v?(\d+\.\d+\.\d+)", output)
    return m.group(1) if m else None


def parse_golangci_lint_version_output(output: str) -> Optional[str]:
    # e.g. golangci-lint has version 1.59.1 built from ...
    m = re.search(r"version\s+(\d+\.\d+\.\d+)", output)
    return m.group(1) if m else None


def command_exists_any(candidates: List[str]) -> Optional[str]:
    for c in candidates:
        if shutil.which(c):
            return c
    return None


# -----------------------------
# Checks
# -----------------------------
def check_required_files(root: Path, report: VerificationReport) -> None:
    for rel in REQUIRED_FILES:
        p = root / rel
        if p.exists():
            report.add_pass("FILE_EXISTS", f"{rel} exists")
        else:
            report.add_fail("FILE_MISSING", f"Required file missing: {rel}")


def check_os_python(report: VerificationReport) -> str:
    os_name = platform.system()
    py_cmd = detect_python_command()
    code, out, err = run_command([py_cmd, "--version"])
    if code == 0:
        report.add_pass("PYTHON", f"{os_name} | {out or err}")
    else:
        report.add_fail("PYTHON", f"Unable to execute {py_cmd} --version ({err})")
    return py_cmd


def check_base_commands(report: VerificationReport) -> None:
    for cmd in REQUIRED_COMMANDS:
        # windows frequently has python not python3
        if cmd == "python3" and platform.system() == "Windows":
            found = shutil.which("python3") or shutil.which("python")
            if found:
                report.add_pass("CMD_EXISTS", f"python runtime found: {Path(found).name}")
            else:
                report.add_fail("CMD_MISSING", "python3/python not found in PATH")
            continue

        if shutil.which(cmd):
            report.add_pass("CMD_EXISTS", f"{cmd} found in PATH")
        else:
            report.add_fail("CMD_MISSING", f"{cmd} not found in PATH")


def check_go_mod(root: Path, report: VerificationReport) -> None:
    go_mod = root / "go.mod"
    content = read_text_file(go_mod)
    if content is None:
        report.add_fail("GO_MOD_READ", "Unable to read go.mod")
        return

    match = None
    for line in content.splitlines():
        m = GO_VERSION_RE.match(line.strip())
        if m:
            match = m.group(1)
            break

    if match:
        report.add_pass("GO_MOD_VERSION", f"go.mod declares Go {match}")
    else:
        report.add_fail("GO_MOD_VERSION", "No valid 'go <major.minor>' directive found in go.mod")


def check_tool_versions(root: Path, report: VerificationReport) -> Dict[str, str]:
    path = root / "tooling/.tool-versions"
    tools = parse_tool_versions(path)
    required = {"terraform", "tflint", "trivy", "golangci-lint"}

    if not tools:
        report.add_fail("TOOL_VERSIONS_PARSE", "Failed to parse tooling/.tool-versions or file is empty")
        return tools

    missing = required - set(tools.keys())
    if missing:
        report.add_fail("TOOL_VERSIONS_KEYS", f"Missing required tools in .tool-versions: {sorted(missing)}")
    else:
        report.add_pass("TOOL_VERSIONS_KEYS", "All required tool keys exist in .tool-versions")

    for tool in required & set(tools.keys()):
        ver = normalize_version(tools[tool])
        if SEMVER_RE.match(ver):
            report.add_pass("TOOL_VERSION_FORMAT", f"{tool} version format OK: {tools[tool]}")
        else:
            report.add_warn("TOOL_VERSION_FORMAT", f"{tool} version may be non-semver: {tools[tool]}")

    return tools


def check_terraform_sot(root: Path, tools: Dict[str, str], report: VerificationReport) -> None:
    tf_file = root / "tooling/.terraform-version"
    tf_ver = read_text_file(tf_file)
    if not tf_ver:
        report.add_fail("TF_SOT_READ", "Unable to read tooling/.terraform-version")
        return

    tf_ver_norm = normalize_version(tf_ver)
    if not SEMVER_RE.match(tf_ver_norm):
        report.add_fail("TF_SOT_FORMAT", f"Invalid terraform version format in .terraform-version: {tf_ver}")
        return

    report.add_pass("TF_SOT_FORMAT", f".terraform-version is valid: {tf_ver}")

    tool_tf = normalize_version(tools.get("terraform", ""))
    if tool_tf:
        if tool_tf == tf_ver_norm:
            report.add_pass("TF_SOT_MATCH", "terraform version matches between .terraform-version and .tool-versions")
        else:
            report.add_fail(
                "TF_SOT_MATCH",
                f"Mismatch terraform versions: .terraform-version={tf_ver_norm}, .tool-versions={tool_tf}",
            )


def check_installed_tool_versions(tools: Dict[str, str], report: VerificationReport) -> None:
    check_matrix = {
        "terraform": (["terraform", "version"], parse_terraform_version_output),
        "tflint": (["tflint", "--version"], parse_tflint_version_output),
        "trivy": (["trivy", "version"], parse_trivy_version_output),
        "golangci-lint": (["golangci-lint", "version"], parse_golangci_lint_version_output),
    }

    for tool, expected_raw in tools.items():
        if tool not in check_matrix:
            continue

        exec_name = command_exists_any(TOOL_EXECUTABLE_MAP.get(tool, [tool]))
        if not exec_name:
            report.add_fail("TOOL_NOT_INSTALLED", f"{tool} not found in PATH")
            continue

        cmd, parser = check_matrix[tool]
        cmd = [exec_name] + cmd[1:]
        rc, out, err = run_command(cmd, timeout=DEFAULT_CMD_TIMEOUT)
        if rc != 0:
            if rc in (124, 130):
                report.add_warn(
                    "TOOL_VERSION_CMD",
                    f"{tool} version command did not complete cleanly (rc={rc}): {err or out}",
                )
            else:
                report.add_fail("TOOL_VERSION_CMD", f"{tool} version command failed: {err or out}")
            continue

        actual = parser(out or err)
        expected = normalize_version(expected_raw)

        if not actual:
            report.add_warn("TOOL_VERSION_PARSE", f"Could not parse installed version for {tool}")
            continue

        if normalize_version(actual) == expected:
            report.add_pass("TOOL_VERSION_MATCH", f"{tool} installed version matches expected ({expected})")
        else:
            report.add_warn(
                "TOOL_VERSION_MATCH",
                f"{tool} installed={actual} expected={expected} (mismatch)",
            )


# -----------------------------
# Main
# -----------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Verify development/CI environment consistency.")
    parser.add_argument("--root", required=True, help="Repository root path")
    parser.add_argument("--strict", action="store_true", help="Fail on warnings as well as failures")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    report = VerificationReport()

    if not root.exists() or not root.is_dir():
        print(f"❌ [FAIL] ROOT_PATH: Invalid root path: {root}")
        return 2

    try:
        check_required_files(root, report)
        check_os_python(report)
        check_base_commands(report)
        check_go_mod(root, report)
        tools = check_tool_versions(root, report)
        check_terraform_sot(root, tools, report)
        check_installed_tool_versions(tools, report)
    except KeyboardInterrupt:
        report.add_fail("INTERRUPTED", "Verification interrupted by signal (KeyboardInterrupt)")
        report.print()
        return 130
    except Exception as exc:  # noqa: BLE001
        report.add_fail("UNEXPECTED", f"Unhandled exception during verification: {exc}")
        report.print()
        return 1

    report.print()

    if report.has_failures:
        return 1
    if args.strict and report.has_warnings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
