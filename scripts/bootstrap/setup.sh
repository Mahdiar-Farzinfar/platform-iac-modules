#!/usr/bin/env bash
# shellcheck shell=bash
#
# Thin wrapper for bootstrap SoT script (setup.py).
# Responsibilities:
# - Resolve repository root deterministically
# - Select a suitable Python interpreter (>=3.10 expected by setup.py)
# - Delegate execution and preserve exit code
#
# All bootstrap logic lives in: scripts/bootstrap/setup.py

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  printf '[bootstrap:setup.sh][ERROR] bash is required but was not found in PATH.\n' >&2
  exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

readonly WRAPPER_NAME="bootstrap:setup.sh"

log() {
  printf '[%s] %s\n' "${WRAPPER_NAME}" "$*"
}

err() {
  printf '[%s][ERROR] %s\n' "${WRAPPER_NAME}" "$*" >&2
}

# Resolve this script directory robustly (supports invocation via symlink/cwd)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
SETUP_PY="${SCRIPT_DIR}/setup.py"

if [[ ! -f "${SETUP_PY}" ]]; then
  err "SoT script not found: ${SETUP_PY}"
  exit 3
fi

# Pick python interpreter: prefer python3, fallback python
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  err "Python interpreter not found in PATH (requires Python >= 3.10)."
  exit 2
fi

# Optional pre-check for clearer UX before delegating.
# setup.py also validates python version; this is just early feedback.
PY_VER="$("${PYTHON_BIN}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
if [[ -z "${PY_VER}" ]]; then
  err "Unable to determine Python version from: ${PYTHON_BIN}"
  exit 2
fi

log "Using Python: ${PYTHON_BIN} (v${PY_VER})"
log "Delegating to SoT: ${SETUP_PY}"

# Execute from repo root for deterministic relative-path behavior.
cd -- "${ROOT_DIR}"

# Pass all CLI args through unchanged and preserve exit contract from setup.py.
exec "${PYTHON_BIN}" "${SETUP_PY}" "$@"
