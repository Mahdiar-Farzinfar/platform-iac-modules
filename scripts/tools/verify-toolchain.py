#!/usr/bin/env python3
"""
verify-toolchain.py

Purpose:
- Read canonical toolchain versions from:
  - tooling/.tool-versions
  - tooling/.terraform-version
  - go.mod
- Verify mirror files are in sync:
  - tooling/cross-platform/asdf-tool-versions
  - .devcontainer/devcontainer.json (features.terraform/go)
- Emit CI-friendly logs and GitHub Actions outputs.

Usage:
  python verify-toolchain.py \
    --root "." \
    --tool-versions-file "tooling/.tool-versions" \
    --terraform-version-file "tooling/.terraform-version" \
    --go-mod-file "go.mod"

Exit codes:
  0 => all checks passed
  1 => verification failed (mismatch / parse errors / missing files)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# ---------- Logging ----------

def log_info(msg: str) -> None:
    print(f"[INFO] {msg}")


def log_warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def log_error(msg: str) -> None:
    print(f"[ERROR] {msg}")


# ---------- Data structures ----------

@dataclass(frozen=True)
class CanonicalVersions:
    terraform: str
    go: str
    tools: Dict[str, str]  # from tooling/.tool-versions (e.g. python, nodejs, golang ...)


@dataclass
class VerificationIssue:
    location: str
    key: str
    expected: str
    actual: str
    message: str


# ---------- Parsers ----------

TOOL_VERSIONS_LINE_RE = re.compile(r"^\s*([A-Za-z0-9._+-]+)\s+(.+?)\s*$")
GO_MOD_GO_RE = re.compile(r"^\s*go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$", re.MULTILINE)
# Example: toolchain go1.22.3
GO_MOD_TOOLCHAIN_RE = re.compile(r"^\s*toolchain\s+go([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$", re.MULTILINE)


def normalize_version(v: str) -> str:
    return v.strip().lstrip("v")


def parse_tool_versions(path: Path) -> Dict[str, str]:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")

    tools: Dict[str, str] = {}
    for idx, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        m = TOOL_VERSIONS_LINE_RE.match(raw)
        if not m:
            raise ValueError(f"Invalid .tool-versions format at {path}:{idx}: {raw}")

        name, version_expr = m.groups()
        # keep only first token for strict deterministic checks
        # (asdf can support complex expressions, but enterprise repos usually pin exact versions)
        version = version_expr.split()[0].strip()
        tools[name] = normalize_version(version)

    if not tools:
        raise ValueError(f"No tools found in {path}")

    return tools


def parse_terraform_version(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")
    content = path.read_text(encoding="utf-8").strip()
    if not content:
        raise ValueError(f"Empty terraform version file: {path}")
    return normalize_version(content.splitlines()[0])


def parse_go_version_from_mod(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")
    content = path.read_text(encoding="utf-8")

    # prefer toolchain directive (more explicit for actual toolchain)
    m_toolchain = GO_MOD_TOOLCHAIN_RE.search(content)
    if m_toolchain:
        return normalize_version(m_toolchain.group(1))

    m_go = GO_MOD_GO_RE.search(content)
    if m_go:
        return normalize_version(m_go.group(1))

    raise ValueError(f"Could not find 'go' or 'toolchain goX.Y.Z' directive in {path}")


def parse_devcontainer_versions(path: Path) -> Dict[str, str]:
    """
    Parse versions from .devcontainer/devcontainer.json:
      features: {
        "ghcr.io/devcontainers/features/terraform:1": { "version": "1.9.8" },
        "ghcr.io/devcontainers/features/go:1": { "version": "1.22.5" }
      }
    """
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")

    obj = json.loads(path.read_text(encoding="utf-8"))
    features = obj.get("features", {})
    out: Dict[str, str] = {}

    for feature_id, cfg in features.items():
        fid = str(feature_id).lower()
        if not isinstance(cfg, dict):
            continue
        version = cfg.get("version")
        if not version:
            continue
        if "terraform" in fid:
            out["terraform"] = normalize_version(str(version))
        elif re.search(r"(^|/|-)go(:|/|$)", fid):
            out["go"] = normalize_version(str(version))

    return out


# ---------- Verification ----------

def read_canonical(root: Path, tool_versions_file: str, terraform_version_file: str, go_mod_file: str) -> CanonicalVersions:
    tv_path = (root / tool_versions_file).resolve()
    tf_path = (root / terraform_version_file).resolve()
    gm_path = (root / go_mod_file).resolve()

    tools = parse_tool_versions(tv_path)
    terraform = parse_terraform_version(tf_path)
    go = parse_go_version_from_mod(gm_path)

    return CanonicalVersions(terraform=terraform, go=go, tools=tools)


def verify_cross_platform_asdf(root: Path, canonical: CanonicalVersions, issues: List[VerificationIssue]) -> None:
    path = (root / "tooling/cross-platform/asdf-tool-versions").resolve()
    mirror = parse_tool_versions(path)

    # check all canonical tools exist with exact versions in mirror
    for tool, expected in canonical.tools.items():
        actual = mirror.get(tool)
        if actual is None:
            issues.append(
                VerificationIssue(
                    location=str(path),
                    key=tool,
                    expected=expected,
                    actual="<missing>",
                    message="Tool missing in cross-platform asdf mirror",
                )
            )
            continue
        if normalize_version(actual) != normalize_version(expected):
            issues.append(
                VerificationIssue(
                    location=str(path),
                    key=tool,
                    expected=expected,
                    actual=actual,
                    message="Tool version mismatch in cross-platform asdf mirror",
                )
            )


def verify_devcontainer(root: Path, canonical: CanonicalVersions, issues: List[VerificationIssue]) -> None:
    path = (root / ".devcontainer/devcontainer.json").resolve()
    if not path.is_file():
        log_info(f"Skipping devcontainer mirror verification; file not present: {path}")
        return

    versions = parse_devcontainer_versions(path)

    # terraform
    actual_tf = versions.get("terraform")
    if actual_tf is None:
        issues.append(
            VerificationIssue(
                location=str(path),
                key="terraform",
                expected=canonical.terraform,
                actual="<missing>",
                message="Terraform version missing in devcontainer features",
            )
        )
    elif normalize_version(actual_tf) != normalize_version(canonical.terraform):
        issues.append(
            VerificationIssue(
                location=str(path),
                key="terraform",
                expected=canonical.terraform,
                actual=actual_tf,
                message="Terraform version mismatch in devcontainer",
            )
        )

    # go
    actual_go = versions.get("go")
    if actual_go is None:
        issues.append(
            VerificationIssue(
                location=str(path),
                key="go",
                expected=canonical.go,
                actual="<missing>",
                message="Go version missing in devcontainer features",
            )
        )
    elif normalize_version(actual_go) != normalize_version(canonical.go):
        issues.append(
            VerificationIssue(
                location=str(path),
                key="go",
                expected=canonical.go,
                actual=actual_go,
                message="Go version mismatch in devcontainer",
            )
        )


def write_github_output(key: str, value: str) -> None:
    output_file = os.getenv("GITHUB_OUTPUT")
    if not output_file:
        return
    with open(output_file, "a", encoding="utf-8") as f:
        f.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify canonical toolchain versions and mirror consistency.")
    parser.add_argument("--root", required=True, help="Repository root directory")
    parser.add_argument("--tool-versions-file", required=True, help="Path to canonical .tool-versions file (relative to root)")
    parser.add_argument("--terraform-version-file", required=True, help="Path to canonical .terraform-version file (relative to root)")
    parser.add_argument("--go-mod-file", required=True, help="Path to go.mod file (relative to root)")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    issues: List[VerificationIssue] = []

    try:
        canonical = read_canonical(
            root=root,
            tool_versions_file=args.tool_versions_file,
            terraform_version_file=args.terraform_version_file,
            go_mod_file=args.go_mod_file,
        )
    except Exception as e:
        log_error(f"Failed to read canonical versions: {e}")
        write_github_output("toolchain_status", "failed")
        return 1

    log_info(f"Canonical terraform={canonical.terraform}, go={canonical.go}")
    log_info(f"Canonical tools count={len(canonical.tools)}")

    try:
        verify_cross_platform_asdf(root, canonical, issues)
    except Exception as e:
        log_error(f"Failed verifying cross-platform asdf mirror: {e}")
        write_github_output("toolchain_status", "failed")
        return 1

    try:
        verify_devcontainer(root, canonical, issues)
    except Exception as e:
        log_error(f"Failed verifying devcontainer mirror: {e}")
        write_github_output("toolchain_status", "failed")
        return 1

    if issues:
        log_error("Toolchain verification failed with mismatches:")
        for i, issue in enumerate(issues, start=1):
            log_error(
                f"{i}. [{issue.location}] {issue.key}: expected={issue.expected}, actual={issue.actual} | {issue.message}"
            )
        write_github_output("toolchain_status", "failed")
        write_github_output("toolchain_mismatch_count", str(len(issues)))
        return 1

    log_info("Toolchain verification passed. All mirrors are consistent with canonical versions.")
    write_github_output("toolchain_status", "ok")
    write_github_output("toolchain_mismatch_count", "0")
    write_github_output("terraform_version", canonical.terraform)
    write_github_output("go_version", canonical.go)
    return 0


if __name__ == "__main__":
    sys.exit(main())
