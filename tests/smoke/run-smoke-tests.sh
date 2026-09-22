#!/usr/bin/env bash
#
# Thin POSIX-shell wrapper for tests/smoke/run-smoke-tests.py (the SoT).
#
# Responsibilities are intentionally minimal:
#   1. Resolve a Python 3 interpreter.
#   2. Forward all arguments, unchanged, to run-smoke-tests.py.
#   3. Propagate its exit code verbatim (0 ok, 1 checks failed,
#      2 internal error, 130 interrupted).
#
# All flags and behavior are documented in run-smoke-tests.py --help.

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]]; then
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}" >/dev/null 2>&1 && pwd -P)"
SOT="${SCRIPT_DIR}/run-smoke-tests.py"

if [[ ! -f "${SOT}" ]]; then
  echo "error: source-of-truth script not found: ${SOT}" >&2
  exit 2
fi

# Prefer an explicit override, then a verified python3, then a `python` that
# is Python 3. SMOKE_PYTHON is an executable name or path, not a command line.
is_python3() {
  local candidate="$1"

  "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' \
    >/dev/null 2>&1
}

resolve_python() {
  if [[ -n "${SMOKE_PYTHON:-}" ]]; then
    local override
    override="$(command -v -- "${SMOKE_PYTHON}" 2>/dev/null || true)"
    if [[ -n "${override}" ]] && is_python3 "${override}"; then
      printf '%s\n' "${override}"
      return 0
    fi
    echo "error: SMOKE_PYTHON must resolve to a Python 3 executable: ${SMOKE_PYTHON}" >&2
    return 1
  fi

  local candidate
  candidate="$(command -v -- python3 2>/dev/null || true)"
  if [[ -n "${candidate}" ]] && is_python3 "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  candidate="$(command -v -- python 2>/dev/null || true)"
  if [[ -n "${candidate}" ]] && is_python3 "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  echo "error: no Python 3 interpreter found on PATH (tried: python3, python)." >&2
  echo "hint: install Python 3 or set SMOKE_PYTHON=/path/to/python3" >&2
  return 1
}

PYTHON="$(resolve_python)" || exit 2

# exec: replace the shell so signals (e.g. Ctrl-C -> 130) and the exit code
# reach the caller directly from the Python process.
exec "${PYTHON}" "${SOT}" "$@"
