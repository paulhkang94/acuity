#!/usr/bin/env bash
# test-launchd-env.sh — runtime validator for launchd agent PATH/interpreter resolution
# Usage: test-launchd-env.sh [--plist-dir DIR]
set -euo pipefail

PLIST_DIR="${HOME}/Library/LaunchAgents"

FAIL_COUNT=0
WARN_COUNT=0
PLIST_COUNT=0

# Color output only when connected to a terminal
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
else
  RED=''
  YELLOW=''
  GREEN=''
  RESET=''
fi

_usage() {
  cat <<EOF
Usage: test-launchd-env.sh [OPTIONS]

Validates that all installed launchd agents can resolve their interpreters
under the stripped PATH specified in each plist's environment.

OPTIONS:
  --plist-dir DIR   directory to scan for .plist files (default: ~/Library/LaunchAgents)
  --help            show this help
EOF
}

_emit_fail() {
  local label="$1" msg="$2"
  echo -e "${RED}FAIL${RESET}  [${label}] ${msg}"
  (( FAIL_COUNT++ )) || true
}

_emit_warn() {
  local label="$1" msg="$2"
  echo -e "${YELLOW}WARN${RESET}  [${label}] ${msg}"
  (( WARN_COUNT++ )) || true
}

_emit_ok() {
  local label="$1" msg="$2"
  echo -e "${GREEN}OK${RESET}    [${label}] ${msg}"
}

# Extract a plist value by key (simple single-key lookup, XML grep approach)
_plist_value() {
  local file="$1" key="$2"
  grep -A1 "<key>${key}</key>" "$file" 2>/dev/null \
    | grep '<string>' \
    | sed 's/.*<string>\(.*\)<\/string>.*/\1/' \
    | head -1 || true
}

# Extract the script path from ProgramArguments (last .sh path, or last absolute path in array)
_plist_script() {
  local file="$1"
  # Only scan within the ProgramArguments <array>...</array> block — stop at </array>
  awk '/<key>ProgramArguments<\/key>/{found=1; next}
       found && /<\/array>/{exit}
       found && /<string>/{print}' "$file" 2>/dev/null \
    | sed 's/.*<string>\(.*\)<\/string>.*/\1/' \
    | grep '\.sh$' \
    | tail -1 \
  || awk '/<key>ProgramArguments<\/key>/{found=1; next}
          found && /<\/array>/{exit}
          found && /<string>\//{ print }' "$file" 2>/dev/null \
    | sed 's/.*<string>\(.*\)<\/string>.*/\1/' \
    | grep -v '^/bin/\|^/usr/bin/' \
    | tail -1 \
  || true
}

_check_plist() {
  local plist="$1"
  (( PLIST_COUNT++ )) || true

  local label
  label="$(_plist_value "$plist" "Label")"
  if [[ -z "$label" ]]; then
    label="$(basename "$plist" .plist)"
  fi

  # 1. Extract PATH; fall back to bare launchd default
  local plist_path
  plist_path="$(_plist_value "$plist" "PATH")"
  if [[ -z "$plist_path" ]]; then
    plist_path="/usr/bin:/bin:/usr/sbin:/sbin"
  fi

  # 2. Extract script path
  local script
  script="$(_plist_script "$plist")"

  # 3. Verify script exists on disk
  if [[ -n "$script" ]]; then
    if [[ ! -f "$script" ]]; then
      _emit_fail "$label" "script not found on disk: ${script}"
    fi
  fi

  # 4. Check last launchctl exit status
  local last_exit
  last_exit="$(launchctl list "$label" 2>/dev/null \
    | grep '"LastExitStatus"' \
    | sed 's/.*= \([0-9-]*\).*/\1/' \
    | head -1)" || true
  if [[ -n "$last_exit" && "$last_exit" != "0" ]]; then
    _emit_warn "$label" "last launchctl exit status: ${last_exit}"
  fi

  # 5. Resolve interpreters used in the script
  if [[ -n "$script" && -f "$script" ]]; then
    # Skip binary files (native executables, not shell scripts)
    if ! file "$script" 2>/dev/null | grep -q "text"; then
      _emit_ok "$label" "native binary — skipping interpreter check"
      return 0
    fi

    # Only check UNGUARDED interpreter calls (not preceded by `command -v` on same line)
    local interps
    interps="$(grep -E '^\s*(python3|node|npm|npx|pip)\b' "$script" 2>/dev/null \
      | grep -v 'command\s*-v' \
      | grep -oE '(python3|node|npm|npx|pip)\b' \
      | sort -u)" || true

    local any_checked=0
    local interp
    while IFS= read -r interp; do
      [[ -z "$interp" ]] && continue
      any_checked=1
      if env -i HOME="${HOME}" PATH="${plist_path}" command -v "$interp" >/dev/null 2>&1; then
        local resolved
        resolved="$(env -i HOME="${HOME}" PATH="${plist_path}" command -v "$interp")"
        _emit_ok "$label" "${interp} -> ${resolved}"
      else
        _emit_fail "$label" "'${interp}' not found on plist PATH=${plist_path}"
      fi
    done <<< "$interps"

    if [[ "$any_checked" -eq 0 ]]; then
      _emit_ok "$label" "no unguarded interpreter calls detected in script"
    fi
  elif [[ -z "$script" ]]; then
    _emit_warn "$label" "could not extract script path from ProgramArguments"
  fi
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)       _usage; exit 0 ;;
    --plist-dir)  PLIST_DIR="$2"; shift 2 ;;
    -*)           echo "Unknown option: $1" >&2; _usage >&2; exit 1 ;;
    *)            echo "Unexpected argument: $1" >&2; _usage >&2; exit 1 ;;
  esac
done

if [[ ! -d "$PLIST_DIR" ]]; then
  echo "plist directory not found: ${PLIST_DIR}" >&2
  exit 1
fi

shopt -s nullglob
plists=("${PLIST_DIR}"/*.plist)
shopt -u nullglob

if [[ "${#plists[@]}" -eq 0 ]]; then
  echo "No .plist files found in ${PLIST_DIR}"
  exit 0
fi

echo "Scanning ${#plists[@]} plist(s) in ${PLIST_DIR}"
echo ""

for plist in "${plists[@]}"; do
  _check_plist "$plist"
done

echo ""
echo "${PLIST_COUNT} plist(s) checked — ${FAIL_COUNT} failure(s), ${WARN_COUNT} warning(s)"

[[ "$FAIL_COUNT" -eq 0 ]]
