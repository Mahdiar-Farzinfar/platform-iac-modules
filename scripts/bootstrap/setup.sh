#!/usr/bin/env bash
# shellcheck shell=bash
#
# Thin wrapper for bootstrap SoT script (setup.py).
# Responsibilities:
# - Resolve repository root deterministically
# - Read the pinned Python version from tooling/.tool-versions
# - Ensure a suitable Python interpreter exists (install it if missing)
# - Announce the host environment (OS/arch/wrapper) so setup.py can adapt
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
readonly WRAPPER_KIND="bash"

log() { printf '[%s] %s\n' "${WRAPPER_NAME}" "$*"; }
err() { printf '[%s][ERROR] %s\n' "${WRAPPER_NAME}" "$*" >&2; }

# --- Path resolution (supports invocation via symlink/cwd) -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
SETUP_PY="${SCRIPT_DIR}/setup.py"
TOOL_VERSIONS_FILE="${ROOT_DIR}/tooling/.tool-versions"

if [[ ! -f "${SETUP_PY}" ]]; then
  err "SoT script not found: ${SETUP_PY}"
  exit 3
fi

# --- Environment self-identification -----------------------------------------
# Detects host OS/arch and exports a normalized, stable contract for setup.py:
#   BOOTSTRAP_WRAPPER_KIND   -> "bash"
#   BOOTSTRAP_WRAPPER_OS     -> normalized family: linux|macos|windows|bsd|unknown
#   BOOTSTRAP_WRAPPER_OS_RAW -> raw uname -s
#   BOOTSTRAP_WRAPPER_ARCH   -> normalized: x86_64|arm64|x86|<raw>
#   BOOTSTRAP_WRAPPER_DISTRO -> linux distro id (from /etc/os-release) or ""
#   BOOTSTRAP_WRAPPER_KERNEL -> uname -r
#   BOOTSTRAP_WRAPPER_WSL    -> "1" when running under WSL, else "0"
detect_environment() {
  local uname_s uname_m kernel os arch distro="" is_wsl="0"

  uname_s="$(uname -s 2>/dev/null || printf 'unknown')"
  uname_m="$(uname -m 2>/dev/null || printf 'unknown')"
  kernel="$(uname -r 2>/dev/null || printf 'unknown')"

  case "${uname_s}" in
    Linux*)                os="linux" ;;
    Darwin*)               os="macos" ;;
    CYGWIN*|MINGW*|MSYS*)  os="windows" ;;
    *BSD*|DragonFly*)      os="bsd" ;;
    *)                     os="unknown" ;;
  esac

  case "${uname_m}" in
    x86_64|amd64)          arch="x86_64" ;;
    aarch64|arm64)         arch="arm64" ;;
    i386|i686)             arch="x86" ;;
    *)                     arch="${uname_m}" ;;
  esac

  # Linux distro identification (best-effort; non-fatal).
  if [[ "${os}" == "linux" && -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    distro="$( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" )"
  fi

  # WSL detection (kernel string carries the marker on WSL1/WSL2).
  if [[ "${os}" == "linux" ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    is_wsl="1"
  fi

  export BOOTSTRAP_WRAPPER_KIND="${WRAPPER_KIND}"
  export BOOTSTRAP_WRAPPER_OS="${os}"
  export BOOTSTRAP_WRAPPER_OS_RAW="${uname_s}"
  export BOOTSTRAP_WRAPPER_ARCH="${arch}"
  export BOOTSTRAP_WRAPPER_DISTRO="${distro}"
  export BOOTSTRAP_WRAPPER_KERNEL="${kernel}"
  export BOOTSTRAP_WRAPPER_WSL="${is_wsl}"

  log "Host environment: os=${os} arch=${arch} distro=${distro:-n/a} wsl=${is_wsl} kernel=${kernel} (wrapper=${WRAPPER_KIND})"
}

detect_environment

# --- Required version from tooling/.tool-versions ----------------------------
read_required_python_version() {
  if [[ ! -f "${TOOL_VERSIONS_FILE}" ]]; then
    err "Tool versions file not found: ${TOOL_VERSIONS_FILE}"
    exit 3
  fi
  local version
  version="$(awk '$1 == "python" { print $2; exit }' "${TOOL_VERSIONS_FILE}")"
  if [[ -z "${version}" ]]; then
    err "No 'python <version>' entry found in: ${TOOL_VERSIONS_FILE}"
    exit 3
  fi
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    err "Invalid python version pin '${version}' in: ${TOOL_VERSIONS_FILE}"
    exit 3
  fi
  printf '%s\n' "${version}"
}

REQUIRED_PY_VERSION="$(read_required_python_version)"
log "Required Python version (from tooling/.tool-versions): ${REQUIRED_PY_VERSION}"

# --- Version helpers ----------------------------------------------------------
# version_ge A B -> success if A >= B (numeric, dotted; no external deps)
version_ge() {
  local -a a b
  IFS='.' read -r -a a <<< "$1"
  IFS='.' read -r -a b <<< "$2"
  local i
  for i in 0 1 2; do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

interpreter_version() {
  "$1" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true
}

# --- Interpreter discovery ----------------------------------------------------
PYTHON_BIN=""

find_suitable_python() {
  local candidate resolved ver
  for candidate in python3 python; do
    if resolved="$(command -v "${candidate}" 2>/dev/null)"; then
      ver="$(interpreter_version "${resolved}")"
      if [[ -n "${ver}" ]] && version_ge "${ver}" "${REQUIRED_PY_VERSION}"; then
        PYTHON_BIN="${resolved}"
        return 0
      fi
      log "Skipping ${resolved} (v${ver:-unknown}); requires >= ${REQUIRED_PY_VERSION}"
    fi
  done
  return 1
}

# --- Installation (pinned version via version managers, best-effort fallback) -
install_python() {
  local ver="${REQUIRED_PY_VERSION}"

  if command -v mise >/dev/null 2>&1; then
    log "Installing Python ${ver} via mise..."
    mise install "python@${ver}"
    PYTHON_BIN="$(mise where "python@${ver}")/bin/python3"
    return 0
  fi

  if command -v asdf >/dev/null 2>&1; then
    log "Installing Python ${ver} via asdf..."
    asdf plugin add python >/dev/null 2>&1 || true
    asdf install python "${ver}"
    PYTHON_BIN="$(asdf where python "${ver}")/bin/python3"
    return 0
  fi

  if command -v pyenv >/dev/null 2>&1; then
    log "Installing Python ${ver} via pyenv..."
    pyenv install --skip-existing "${ver}"
    PYTHON_BIN="$(pyenv root)/versions/${ver}/bin/python3"
    return 0
  fi

  # Fallback: system package manager (may not match the exact pin).
  # Uses the normalized OS family detected above to pick a sane installer.
  local sudo_cmd=""
  if [[ "${EUID}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi

  case "${BOOTSTRAP_WRAPPER_OS}" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        log "Installing python via Homebrew (best-effort; exact pin not guaranteed)..."
        brew install "python@${ver%.*}" || brew install python
      else
        err "Homebrew not found on macOS. Install ${ver} manually, then re-run."
        return 1
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        log "Installing python3 via apt-get (best-effort; exact pin not guaranteed)..."
        ${sudo_cmd} apt-get update -y
        ${sudo_cmd} apt-get install -y python3
      elif command -v dnf >/dev/null 2>&1; then
        log "Installing python3 via dnf (best-effort; exact pin not guaranteed)..."
        ${sudo_cmd} dnf install -y python3
      elif command -v pacman >/dev/null 2>&1; then
        log "Installing python via pacman (best-effort; exact pin not guaranteed)..."
        ${sudo_cmd} pacman -Sy --noconfirm python
      else
        err "No supported Linux installer found (apt-get/dnf/pacman)."
        err "Install Python ${ver} manually, then re-run this script."
        return 1
      fi
      ;;
    *)
      err "No supported installer for OS='${BOOTSTRAP_WRAPPER_OS}' (mise/asdf/pyenv also absent)."
      err "Install Python ${ver} manually, then re-run this script."
      return 1
      ;;
  esac

  PYTHON_BIN="$(command -v python3 || true)"
  [[ -n "${PYTHON_BIN}" ]]
}

# --- Ensure interpreter --------------------------------------------------------
if ! find_suitable_python; then
  log "No suitable Python found in PATH; attempting installation..."
  if ! install_python; then
    err "Python installation failed."
    exit 2
  fi
fi

if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  err "Python interpreter is not executable after resolution: '${PYTHON_BIN:-<empty>}'"
  exit 2
fi

PY_VER="$(interpreter_version "${PYTHON_BIN}")"
if [[ -z "${PY_VER}" ]]; then
  err "Unable to determine Python version from: ${PYTHON_BIN}"
  exit 2
fi
if ! version_ge "${PY_VER}" "${REQUIRED_PY_VERSION}"; then
  err "Resolved Python v${PY_VER} does not satisfy required v${REQUIRED_PY_VERSION}."
  exit 2
fi

log "Using Python: ${PYTHON_BIN} (v${PY_VER})"
log "Delegating to SoT: ${SETUP_PY}"

# Execute from repo root for deterministic relative-path behavior.
cd -- "${ROOT_DIR}"

# Pass all CLI args through unchanged and preserve exit contract from setup.py.
# Environment self-identification (BOOTSTRAP_WRAPPER_*) is inherited by setup.py.
exec "${PYTHON_BIN}" "${SETUP_PY}" "$@"
