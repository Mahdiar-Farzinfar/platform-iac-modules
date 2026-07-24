#!/usr/bin/env python3
"""
validate-outputs.py

Validate CI-provided tool version outputs against strict, allowlisted patterns
to prevent output/command/path injection across automation layers (Taskfile, shell, workflows).

Usage:
  python3 scripts/tools/validate-outputs.py \
      --go "1.22.3" \
      --terraform "1.15.6" \
      --python "3.12.4" \
      --tflint "0.56.0" \
      --terraform-docs "0.18.0"

  python3 scripts/tools/validate-outputs.py \
      --root . \
      --go-mod-file go.mod \
      --terraform-version-file tooling/.terraform-version \
      --tool-versions-file tooling/.tool-versions

  Resolution precedence (fail-closed):
    1) non-empty CLI flag
    2) non-empty allowlisted env var
    3) parsed source-of-truth file (when path flags provided)

Exit codes:
  0: All values valid
  1: One or more values invalid
  2: Runtime/internal error
"""

from __future__ import annotations

import argparse
import json
import re
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Pattern, Tuple

# -----------------------------------------------------------------------------
# Security Baseline
# -----------------------------------------------------------------------------
# combine:
# 1) Hard denylist for dangerous characters/tokens often involved in shell/template injection
# 2) Strict allowlist regex for each expected version format
# -----------------------------------------------------------------------------

@dataclass(frozen=True)
class Rule:
    name: str
    pattern: Pattern[str]
    example: str
    required: bool = True
    env_keys: Tuple[str, ...] = ()

DENYLIST_PATTERN = re.compile(r"[\r\n\t`$|&;<>(){}\[\]\\]|(\.\.)|(%0a|%0d)", re.IGNORECASE)

# Length guardrail to avoid weird payloads
MAX_LEN = 32
MIN_LEN = 1

# Strict version format:
# - X.Y.Z
# - Optional pre-release/build metadata: -rc.1, +build.1
SEMVER_STRICT = r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
SEMVER_TOKEN = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
)
GO_MOD_GO_DIRECTIVE = re.compile(
    r"(?m)^\s*go\s+(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?\s*$"
)
ASDF_TOOL_LINE = re.compile(
    r"(?m)^\s*(?P<tool>[A-Za-z0-9][A-Za-z0-9._-]*)\s+(?P<version>\S+)\s*$"
)


RULES: Tuple[Rule, ...] = (
    Rule(
        name="go",
        pattern=re.compile(SEMVER_STRICT),
        example="1.24.4",
        env_keys=("GO_VERSION", "GO_VER"),
    ),
    Rule(
        name="terraform",
        pattern=re.compile(SEMVER_STRICT),
        example="1.9.8",
        env_keys=("TERRAFORM_VERSION", "TF_VERSION"),
    ),
    Rule(
        name="python",
        pattern=re.compile(SEMVER_STRICT),
        example="3.12.4",
        env_keys=("PYTHON_VERSION", "PY_VERSION"),
    ),
    Rule(
        name="tflint",
        pattern=re.compile(SEMVER_STRICT),
        example="0.53.0",
        env_keys=("TFLINT_VERSION",),
    ),
    Rule(
        name="terraform-docs",
        pattern=re.compile(SEMVER_STRICT),
        example="0.18.0",
        env_keys=("TERRAFORM_DOCS_VERSION", "TFDOCS_VERSION"),
    ),
)


@dataclass
class ValidationError:
    field: str
    reason: str
    value_preview: str


def mask_value(value: str, max_chars: int = 24) -> str:
    """Safely preview untrusted input in logs."""
    if value is None:
        return "<null>"
    safe = value.encode("unicode_escape").decode("ascii")
    if len(safe) <= max_chars:
        return safe
    return f"{safe[:max_chars]}…(len={len(safe)})"


def first_non_empty(*candidates: Optional[str]) -> Optional[str]:
    """Return the first candidate that is non-None and non-blank after strip."""
    for candidate in candidates:
        if candidate is None:
            continue
        if not isinstance(candidate, str):
            continue
        if candidate.strip():
            return candidate
    return None


def resolve_from_env(env_keys: Tuple[str, ...]) -> Optional[str]:
    """Resolve version from the first populated environment variable."""
    for key in env_keys:
        value = os.environ.get(key)
        if value is not None and value.strip():
            return value
    return None


def _safe_path(path_value: Optional[str], *, root: Optional[Path] = None) -> Optional[Path]:
    """Resolve a user-supplied path without allowing empty/null values."""
    if path_value is None:
        return None
    raw = str(path_value).strip()
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute() and root is not None:
        path = root / path
    return path


def _read_text(path: Path) -> str:
    """Read text file as UTF-8 with BOM tolerance."""
    return path.read_text(encoding="utf-8-sig")


def normalize_semver(value: str) -> Optional[str]:
    """
    Extract/normalize a plain semver token.
    - Accepts optional leading 'v'
    - Normalizes Go-style X.Y -> X.Y.0
    - Rejects multi-token / path-like payloads by extracting at most one token
    """
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None

    if text.startswith(("v", "V")) and len(text) > 1 and text[1].isdigit():
        text = text[1:]

    # Fast path: already strict X.Y.Z(+meta)
    if re.fullmatch(SEMVER_STRICT, text):
        return text

    # Go toolchain style: 1.22
    if re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)", text):
        return f"{text}.0"

    match = SEMVER_TOKEN.search(text)
    if not match:
        # Last chance for X.Y embedded in noisy strings
        m2 = re.search(r"(0|[1-9]\d*)\.(0|[1-9]\d*)(?!\d)", text)
        if m2:
            return f"{m2.group(0)}.0"
        return None
    return match.group(0)


def parse_go_mod_version(content: str) -> Optional[str]:
    """Parse `go X.Y` / `go X.Y.Z` from go.mod content."""
    match = GO_MOD_GO_DIRECTIVE.search(content)
    if not match:
        return None
    major, minor, patch = match.group(1), match.group(2), match.group(3)
    if patch is None:
        return f"{major}.{minor}.0"
    return f"{major}.{minor}.{patch}"


def parse_plain_version_file(content: str) -> Optional[str]:
    """Parse first non-empty, non-comment line from .terraform-version-like files."""
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return normalize_semver(stripped)
    return None


def parse_tool_versions(content: str) -> Dict[str, str]:
    """
    Parse asdf-style .tool-versions:
      <tool> <version>
    Returns map of tool -> pure semver (best effort).
    """
    found: Dict[str, str] = {}
    for match in ASDF_TOOL_LINE.finditer(content):
        tool = match.group("tool").strip().lower()
        version = normalize_semver(match.group("version"))
        if version:
            found[tool] = version
    return found


def resolve_from_files(
    *,
    root: Optional[Path],
    go_mod_file: Optional[str],
    terraform_version_file: Optional[str],
    tool_versions_file: Optional[str],
) -> Dict[str, Optional[str]]:
    """
    Resolve tool versions from repository source-of-truth files.
    Missing/unreadable files yield None for related fields (fail closed later).
    """
    resolved: Dict[str, Optional[str]] = {
        "go": None,
        "terraform": None,
        "python": None,
        "tflint": None,
        "terraform-docs": None,
    }

    go_mod_path = _safe_path(go_mod_file, root=root)
    tf_ver_path = _safe_path(terraform_version_file, root=root)
    tools_path = _safe_path(tool_versions_file, root=root)

    if go_mod_path is not None and go_mod_path.is_file():
        try:
            resolved["go"] = parse_go_mod_version(_read_text(go_mod_path))
        except OSError:
            resolved["go"] = None

    if tf_ver_path is not None and tf_ver_path.is_file():
        try:
            resolved["terraform"] = parse_plain_version_file(_read_text(tf_ver_path))
        except OSError:
            resolved["terraform"] = None

    if tools_path is not None and tools_path.is_file():
        try:
            tools = parse_tool_versions(_read_text(tools_path))
        except OSError:
            tools = {}

        # Prefer dedicated keys; allow common aliases when present.
        resolved["python"] = tools.get("python") or tools.get("python3")
        resolved["tflint"] = tools.get("tflint")
        resolved["terraform-docs"] = tools.get("terraform-docs") or tools.get("terraform_docs")

        # Optional: if .terraform-version is absent, fall back to asdf terraform pin.
        if resolved["terraform"] is None:
            resolved["terraform"] = tools.get("terraform") or tools.get("tf")

        # Optional: go may also be pinned in .tool-versions
        if resolved["go"] is None:
            resolved["go"] = tools.get("golang") or tools.get("go")

    return resolved


def validate_field(rule: Rule, value: Optional[str]) -> Optional[ValidationError]:
    if value is None:
        if rule.required:
            env_hint = ", ".join(rule.env_keys) if rule.env_keys else "n/a"
            return ValidationError(
                rule.name,
                (
                    f"missing required value (pass --{rule.name}, set one of: {env_hint}, "
                    "or provide source files via --go-mod-file/--terraform-version-file/--tool-versions-file)"
                ),
                "<missing>",
            )
        return None

    if not isinstance(value, str):
        return ValidationError(rule.name, "value is not a string", f"<type={type(value).__name__}>")

    v = value.strip()

    if len(v) < MIN_LEN:
        env_hint = ", ".join(rule.env_keys) if rule.env_keys else "n/a"
        return ValidationError(
            rule.name,
            f"value is empty (pass --{rule.name} <semver>, set one of: {env_hint}, or source files)",
            mask_value(value),
        )
    if len(v) > MAX_LEN:
        return ValidationError(rule.name, f"value too long (>{MAX_LEN})", mask_value(v))
    if DENYLIST_PATTERN.search(v):
        return ValidationError(rule.name, "contains forbidden characters/tokens", mask_value(v))
    if not rule.pattern.fullmatch(v):
        return ValidationError(
            rule.name,
            f"does not match expected version format (example: {rule.example})",
            mask_value(v),
        )

    return None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate workflow/task outputs to protect downstream automation from injection."
    )
    # required=False: empty CI interpolations (e.g. --go "") must reach validators,
    # and env fallbacks can still satisfy the field.
    parser.add_argument("--go", dest="go", default=None, help="Go version (e.g., 1.24.4)")
    parser.add_argument("--terraform", dest="terraform", default=None, help="Terraform version (e.g., 1.9.8)")
    parser.add_argument("--python", dest="python", default=None, help="Python version (e.g., 3.12.4)")
    parser.add_argument("--tflint", dest="tflint", default=None, help="TFLint version (e.g., 0.53.0)")
    parser.add_argument(
        "--terraform-docs",
        dest="terraform_docs",
        default=None,
        help="terraform-docs version (e.g., 0.18.0)",
    )
    parser.add_argument(
        "--root",
        dest="root",
        default=None,
        help="Repository root used to resolve relative source-of-truth file paths.",
    )
    parser.add_argument(
        "--go-mod-file",
        dest="go_mod_file",
        default=None,
        help="Path to go.mod (source of Go toolchain version).",
    )
    parser.add_argument(
        "--terraform-version-file",
        dest="terraform_version_file",
        default=None,
        help="Path to .terraform-version (plain semver line).",
    )
    parser.add_argument(
        "--tool-versions-file",
        dest="tool_versions_file",
        default=None,
        help="Path to .tool-versions (asdf format) for python/tflint/terraform-docs/etc.",
    )
    parser.add_argument(
        "--json",
        dest="json_output",
        action="store_true",
        help="Output JSON result (useful for CI parsing).",
    )
    return parser


def to_input_map(args: argparse.Namespace) -> Dict[str, Optional[str]]:
    """
    Resolve each tool version with precedence:
      1) non-empty CLI flag
      2) first non-empty allowlisted env var
      3) source-of-truth files (go.mod / .terraform-version / .tool-versions)
      4) otherwise keep empty/missing so validation fails closed
    """
    cli_map: Dict[str, Optional[str]] = {
        "go": args.go,
        "terraform": args.terraform,
        "python": args.python,
        "tflint": args.tflint,
        "terraform-docs": args.terraform_docs,
    }

    root = _safe_path(args.root) if getattr(args, "root", None) else None
    if root is None:
        root = Path.cwd()

    file_map = resolve_from_files(
        root=root,
        go_mod_file=getattr(args, "go_mod_file", None),
        terraform_version_file=getattr(args, "terraform_version_file", None),
        tool_versions_file=getattr(args, "tool_versions_file", None),
    )

    resolved: Dict[str, Optional[str]] = {}
    for rule in RULES:
        cli_value = cli_map.get(rule.name)
        env_value = resolve_from_env(rule.env_keys)
        file_value = file_map.get(rule.name)
        candidate = first_non_empty(cli_value, env_value, file_value)
        resolved[rule.name] = normalize_semver(candidate) if candidate is not None else None

    return {
        "go": resolved["go"],
        "terraform": resolved["terraform"],
        "python": resolved["python"],
        "tflint": resolved["tflint"],
        "terraform-docs": resolved["terraform-docs"],
    }


def main() -> int:
    try:
        parser = build_parser()
        args = parser.parse_args()
        inputs = to_input_map(args)

        errors: List[ValidationError] = []
        for rule in RULES:
            err = validate_field(rule, inputs.get(rule.name))
            if err:
                errors.append(err)

        if args.json_output:
            payload = {
                "ok": len(errors) == 0,
                "errors": [
                    {
                        "field": e.field,
                        "reason": e.reason,
                        "value_preview": e.value_preview,
                    }
                    for e in errors
                ],
                "validated_fields": list(inputs.keys()),
                "resolved_values": inputs,
            }
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            if errors:
                print("❌ Output validation failed.")
                for e in errors:
                    print(f"  - [{e.field}] {e.reason}; value={e.value_preview}")
                print("Hint: ensure tool versions are plain semver values (e.g., 1.2.3).")
                print(
                    "Hint: empty values usually mean source-of-truth files are missing keys "
                    "(go.mod / tooling/.terraform-version / tooling/.tool-versions), "
                    "or upstream CI/Task did not pass versions."
                )
            else:
                print("✅ Output validation passed. All values match safe version patterns.")

        return 1 if errors else 0

    except Exception as ex:  # noqa: BLE001
        print(f"❌ Internal validation error: {type(ex).__name__}: {ex}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
