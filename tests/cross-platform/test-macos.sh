#!/usr/bin/env bash
# macOS cross-platform test suite for platform-iac-modules.
#
# Canonical CI entry point:
#   task test:cross-platform:macos
#
# Keep this script compatible with the Apple-provided Bash 3.2.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [[ "$SCRIPT_DIR" == "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT

readonly TOOLING_DIR="${TOOLING_DIR:-${REPO_ROOT}/tooling}"
readonly MODULES_DIR="${MODULES_DIR:-${REPO_ROOT}/modules}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
readonly TERRAFORM_VERSION_FILE="${TERRAFORM_VERSION_FILE:-${TOOLING_DIR}/.terraform-version}"
readonly TOOL_VERSIONS_FILE="${TOOL_VERSIONS_FILE:-${TOOLING_DIR}/.tool-versions}"
readonly TFLINT_CONFIG="${TFLINT_CONFIG:-${TOOLING_DIR}/.tflint.hcl}"
readonly CHECKOV_CONFIG="${CHECKOV_CONFIG:-${TOOLING_DIR}/.checkov.yml}"
readonly TRIVY_IGNORE="${TRIVY_IGNORE:-${TOOLING_DIR}/.trivyignore}"
readonly YAMLLINT_CONFIG="${YAMLLINT_CONFIG:-${TOOLING_DIR}/.yamllint.yml}"

readonly TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly TFLINT_BIN="${TFLINT_BIN:-tflint}"
readonly CHECKOV_BIN="${CHECKOV_BIN:-checkov}"
readonly TRIVY_BIN="${TRIVY_BIN:-trivy}"

readonly VERIFY_TOOLCHAIN_SCRIPT="${VERIFY_TOOLCHAIN_SCRIPT:-${REPO_ROOT}/scripts/tools/verify-toolchain.py}"
readonly VERIFY_ENV_SCRIPT="${VERIFY_ENV_SCRIPT:-${REPO_ROOT}/scripts/tools/verify-env.py}"
readonly VALIDATE_OUTPUTS_SCRIPT="${VALIDATE_OUTPUTS_SCRIPT:-${REPO_ROOT}/scripts/tools/validate-outputs.py}"
readonly SMOKE_WRAPPER="${SMOKE_WRAPPER:-${REPO_ROOT}/tests/smoke/run-smoke-tests.sh}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
MODULE_FILTER=""
LOG_FILE=""

# Homebrew is commonly outside the runner's inherited PATH on macOS.
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX/sbin" ]]; then
    PATH="$PATH:$BREW_PREFIX/sbin"
    export PATH
  fi
fi

MACOS_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
readonly MACOS_ARCH
CPU_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || printf 'unknown')"
readonly CPU_COUNT
HOST_OS="$(uname -s 2>/dev/null || printf 'unknown')"
readonly HOST_OS

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_RED=$'\033[0;31m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_GREEN=''
  readonly C_YELLOW=''
  readonly C_RED=''
  readonly C_RESET=''
fi

usage() {
  local script_name="${0##*/}"

  printf '%s\n' \
    "Usage: ${script_name} [--help] [--modules FILTER]" \
    "" \
    "Run the macOS cross-platform gates for platform-iac-modules." \
    "FILTER is a module name or modules/<name> path; multiple filters may be" \
    "comma-separated." \
    "" \
    "Environment variables may override tool commands, repository paths, and" \
    "configuration files. OUTPUT_DIR defaults to tests/cross-platform/output and" \
    "receives a transcript at test-macos.log." \
    "" \
    "Exit codes:" \
    "  0  all gates passed" \
    "  1  one or more gates failed" \
    "  2  invalid arguments, unsupported host, or missing prerequisites"
}

info() {
  printf '%s[INFO]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

error() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

exit_status() {
  local status=$1
  trap - ERR
  exit "$status"
}

on_error() {
  error "command failed at line ${1}: ${2}"
}

on_exit() {
  local status=$1

  if [[ -n "$LOG_FILE" ]]; then
    info "Log: ${LOG_FILE}"
  fi
  info "Completed: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"

  exit "$status"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'status=$?; on_exit "$status"' EXIT

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

record_skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf 'SKIP  %s\n' "$1"
}

run_check() {
  local name=$1
  local status
  shift

  info "$name"
  if "$@"; then
    record_pass "$name"
  else
    status=$?
    record_fail "$name"
    if ((status == 130)); then
      return 130
    fi
    return 0
  fi
}

version_pin() {
  local tool=$1
  awk -v tool="$tool" '$1 == tool { print $2; exit }' "$TOOL_VERSIONS_FILE"
}

version_of() {
  local tool=$1
  local output

  case "$tool" in
  "$PYTHON_BIN")
    output="$("$tool" --version 2>&1)"
    ;;
  "$TERRAFORM_BIN")
    output="$("$tool" version 2>&1)"
    ;;
  "$TFLINT_BIN" | "$CHECKOV_BIN" | "$TRIVY_BIN")
    output="$("$tool" --version 2>&1)"
    ;;
  *)
    error "No version probe defined for ${tool}"
    return 1
    ;;
  esac

  printf '%s\n' "$output" |
    grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' |
    head -n1
}

check_version() {
  local label=$1
  local tool=$2
  local expected=$3
  local actual

  expected="${expected#v}"
  if [[ -z "$expected" ]]; then
    error "No version pin found for ${label}"
    record_fail "${label} version pin"
    return
  fi

  if ! actual="$(version_of "$tool")"; then
    record_fail "${label} version probe"
    return
  fi

  if [[ "$actual" == "$expected" ]]; then
    record_pass "${label} ${actual}"
  else
    error "${label} version mismatch on ${MACOS_ARCH}: found ${actual}, expected ${expected}"
    record_fail "${label} version"
  fi
}

require_command() {
  local label=$1
  local command_name=$2

  if command -v "$command_name" >/dev/null 2>&1; then
    record_pass "dependency: ${label}"
    return 0
  fi

  error "Missing ${label} (${command_name}). Run the repository bootstrap task or install the pinned tool from ${TOOL_VERSIONS_FILE}."
  record_fail "dependency: ${label}"
  return 1
}

require_python3() {
  "$PYTHON_BIN" -c \
    'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)'
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_module_filter() {
  local item
  item="$(trim "$1")"
  item="${item#./}"
  item="${item%/}"

  if [[ "$item" == modules/* ]]; then
    item="${item#modules/}"
  fi

  printf '%s' "$item"
}

run_smoke_tests() {
  local item normalized

  if [[ -z "$MODULE_FILTER" ]]; then
    bash "$SMOKE_WRAPPER"
    return $?
  fi

  local args=()
  local items=()

  if [[ -n "$MODULE_FILTER" ]]; then
    IFS=',' read -r -a items <<<"$MODULE_FILTER"
    for item in "${items[@]}"; do
      normalized="$(normalize_module_filter "$item")"
      [[ -n "$normalized" ]] || continue
      args+=(--module "$normalized")
    done
  fi

  if [[ -n "$MODULE_FILTER" && "${#args[@]}" -eq 0 ]]; then
    error "--modules requires at least one non-empty module name"
    return 2
  fi

  bash "$SMOKE_WRAPPER" "${args[@]}"
}

main() {
  local missing=0
  local path

  while (($#)); do
    case "$1" in
    --help | -h)
      usage
      return 0
      ;;
    --modules)
      if (($# < 2)); then
        error "--modules requires a value" usage >&2
        exit_status 2
      fi
      MODULE_FILTER=$2
      shift 2
      ;;
    --modules=*)
      MODULE_FILTER="${1#*=}"
      shift
      ;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit_status 2
      ;;
    esac
  done

  if [[ "$HOST_OS" != "Darwin" ]]; then
    error "This suite must run on macOS; detected ${HOST_OS}"
    exit_status 2
  fi

  cd -- "$REPO_ROOT"
  export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
  export TF_INPUT="${TF_INPUT:-false}"
  export CHECKPOINT_DISABLE="${CHECKPOINT_DISABLE:-1}"
  export PYTHONUTF8="${PYTHONUTF8:-1}"
  export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"

  info "Python executable: $(command -v "$PYTHON_BIN")"
  "$PYTHON_BIN" --version

  mkdir -p -- "$OUTPUT_DIR"
  LOG_FILE="${OUTPUT_DIR}/test-macos.log"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  info "Repository: ${REPO_ROOT} (${MACOS_ARCH}, ${CPU_COUNT} CPUs)"

  if [[ ! -d "$MODULES_DIR" ]]; then
    error "Modules directory not found: ${MODULES_DIR}"
    exit_status 2
  fi

  for path in \
    "$TOOL_VERSIONS_FILE" \
    "$TERRAFORM_VERSION_FILE" \
    "$TFLINT_CONFIG" \
    "$CHECKOV_CONFIG" \
    "$TRIVY_IGNORE" \
    "$YAMLLINT_CONFIG" \
    "$VERIFY_TOOLCHAIN_SCRIPT" \
    "$VERIFY_ENV_SCRIPT" \
    "$VALIDATE_OUTPUTS_SCRIPT" \
    "$SMOKE_WRAPPER"; do
    if [[ ! -f "$path" ]]; then
      error "Required file not found: ${path}"
      missing=1
    fi
  done

  require_command "Terraform" "$TERRAFORM_BIN" || missing=1
  require_command "Python 3" "$PYTHON_BIN" || missing=1
  require_command "TFLint" "$TFLINT_BIN" || missing=1
  require_command "Checkov" "$CHECKOV_BIN" || missing=1
  require_command "Trivy" "$TRIVY_BIN" || missing=1
  require_command "Bash" bash || missing=1
  require_python3 || {
    error "${PYTHON_BIN} is not Python 3"
    missing=1
  }

  if ((missing != 0)); then
    exit_status 2
  fi

  check_version "Terraform" "$TERRAFORM_BIN" \
    "$(tr -d '[:space:]' <"$TERRAFORM_VERSION_FILE")"
  check_version "Python" "$PYTHON_BIN" "$(version_pin python)"
  check_version "TFLint" "$TFLINT_BIN" "$(version_pin tflint)"
  check_version "Checkov" "$CHECKOV_BIN" "$(version_pin checkov)"
  check_version "Trivy" "$TRIVY_BIN" "$(version_pin trivy)"

  run_check \
    "validate-outputs.py" \
    "$PYTHON_BIN" \
    "$VALIDATE_OUTPUTS_SCRIPT" \
    --root "$REPO_ROOT" \
    --go-mod-file "$REPO_ROOT/go.mod" \
    --terraform-version-file "$TERRAFORM_VERSION_FILE" \
    --tool-versions-file "$TOOL_VERSIONS_FILE"

  run_check \
    "verify-toolchain.py" \
    "$PYTHON_BIN" \
    "$VERIFY_TOOLCHAIN_SCRIPT" \
    --root "$REPO_ROOT" \
    --tool-versions-file "$TOOL_VERSIONS_FILE" \
    --terraform-version-file "$TERRAFORM_VERSION_FILE" \
    --go-mod-file "$REPO_ROOT/go.mod"

  run_check \
    "verify-env.py --strict" \
    "$PYTHON_BIN" \
    "$VERIFY_ENV_SCRIPT" \
    --root "$REPO_ROOT" \
    --strict

  run_check "catalog-driven smoke tests" run_smoke_tests

  run_check \
    "Checkov" \
    "$CHECKOV_BIN" \
    -d "$REPO_ROOT" \
    --config-file "$CHECKOV_CONFIG"

  run_check \
    "Trivy" \
    "$TRIVY_BIN" \
    config "$REPO_ROOT" \
    --exit-code 1 \
    --ignorefile "$TRIVY_IGNORE" \
    --severity MEDIUM,HIGH,CRITICAL

  run_check \
    "yamllint" \
    "$PYTHON_BIN" \
    -m yamllint \
    -c "$YAMLLINT_CONFIG" \
    "$REPO_ROOT"

  printf '\nSummary\n-------\nPASS: %d\nFAIL: %d\nSKIP: %d\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

  if ((FAIL_COUNT != 0)); then
    return 1
  fi

  return 0
}

main "$@"
