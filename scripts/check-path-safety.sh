#!/usr/bin/env bash
# check-path-safety.sh — static analysis for path/CWD reliability issues
# Usage: check-path-safety.sh [--plist-dir DIR] [--staged] [--quiet] [FILE...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_DIR="${HOME}/Library/LaunchAgents"
STAGED=0
QUIET=0
FILES=()

FAIL_COUNT=0
WARN_COUNT=0
FILE_COUNT=0

# Color output only when connected to a terminal
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  RESET='\033[0m'
else
  RED=''
  YELLOW=''
  RESET=''
fi

_usage() {
  cat <<EOF
Usage: check-path-safety.sh [OPTIONS] [FILE...]

Static analysis for path/CWD reliability issues in shell scripts and launchd plists.

OPTIONS:
  --plist-dir DIR   also scan plists in DIR (default: ~/Library/LaunchAgents)
  --staged          check files staged for commit (git diff --cached --name-only)
  --quiet           suppress warnings, show failures only
  --help            show this help

FILES:
  Explicit .sh or .plist files to check. Combined with --staged if both given.
EOF
}

_emit_fail() {
  local file="$1" msg="$2"
  echo -e "${RED}FAIL${RESET}  ${file} — ${msg}"
  (( FAIL_COUNT++ )) || true
}

_emit_warn() {
  local file="$1" msg="$2"
  [[ "$QUIET" -eq 1 ]] && return 0
  echo -e "${YELLOW}WARN${RESET}  ${file} — ${msg}"
  (( WARN_COUNT++ )) || true
}

# Returns 0 (true) if the script path appears in any plist ProgramArguments
_is_launchd_script() {
  local script="$1"
  grep -rl "$script" "${PLIST_DIR}"/*.plist 2>/dev/null | grep -q . || return 1
}

_check_sh_file() {
  local file="$1"
  local label
  label="$(basename "$file")"

  # Check 1: set -euo pipefail
  # Exemption: scripts with "# path-safety: no-euo" intentionally use ERR trap instead
  # (hook scripts that must never block tool execution use this pattern)
  if ! grep -q "set -euo pipefail" "$file" && ! grep -q "path-safety: no-euo" "$file"; then
    _emit_fail "${label}" "missing 'set -euo pipefail' (add '# path-safety: no-euo' if ERR trap is intentional)"
  fi

  # Check 2: bare interpreter calls (always warn — it's always a smell)
  local lineno line
  while IFS= read -r line; do
    lineno="${line%%:*}"
    local content="${line#*:}"
    # Match bare interpreter at start of line (optional whitespace), not inside command -v checks
    if echo "$content" | grep -qE '^\s*(python3|node|npm|npx|pip)\b' && \
       ! echo "$content" | grep -qE 'command\s+-v'; then
      _emit_warn "${label}:${lineno}" "bare interpreter call without 'command -v' guard: ${content// /}"
    fi
  done < <(grep -nE '^\s*(python3|node|npm|npx|pip)\b' "$file" || true)

  # Check 3: cd without error handling
  while IFS= read -r line; do
    lineno="${line%%:*}"
    local content="${line#*:}"
    if ! echo "$content" | grep -qE '\|\|'; then
      _emit_warn "${label}:${lineno}" "cd without '||' error handling: ${content// /}"
    fi
  done < <(grep -n '^\s*cd ' "$file" || true)
}

_check_plist_file() {
  local file="$1"
  local label
  label="$(basename "$file")"

  # Check 4: PLACEHOLDER strings
  # Exemption: plists with "path-safety: template-plist" are source templates
  # and intentionally contain PLACEHOLDERs for install-time substitution.
  if grep -q "PLACEHOLDER" "$file" 2>/dev/null && \
     ! grep -q "path-safety: template-plist" "$file" 2>/dev/null; then
    _emit_fail "${label}" "contains PLACEHOLDER string — plist not fully configured"
  fi

  # Check 5: PATH vs interpreter resolution
  local plist_path
  plist_path="$(grep -A1 '<key>PATH</key>' "$file" 2>/dev/null \
    | grep '<string>' \
    | sed 's/.*<string>\(.*\)<\/string>.*/\1/' \
    | head -1)" || true

  if [[ -z "$plist_path" ]]; then
    plist_path="/usr/bin:/bin"
  fi

  for interp in python3 node npm npx pip; do
    if grep -q "$interp" "$file" 2>/dev/null; then
      if ! env -i HOME="${HOME}" PATH="${plist_path}" command -v "$interp" >/dev/null 2>&1; then
        _emit_warn "${label}" "interpreter '${interp}' not found on plist PATH=${plist_path}"
      fi
    fi
  done
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)    _usage; exit 0 ;;
    --staged)  STAGED=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    --plist-dir) PLIST_DIR="$2"; shift 2 ;;
    -*)        echo "Unknown option: $1" >&2; _usage >&2; exit 1 ;;
    *)         FILES+=("$1"); shift ;;
  esac
done

# Collect staged files if requested
if [[ "$STAGED" -eq 1 ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] && FILES+=("$f")
  done < <(git -C "${REPO_ROOT}" diff --cached --name-only 2>/dev/null || true)
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "No files to check. Use --staged or pass FILE args." >&2
  _usage >&2
  exit 1
fi

# Process files
for f in "${FILES[@]}"; do
  (( FILE_COUNT++ )) || true
  case "$f" in
    *.sh)    _check_sh_file "$f" ;;
    *.plist) _check_plist_file "$f" ;;
    *)       : ;;  # skip unknown types silently
  esac
done

echo ""
echo "${FILE_COUNT} file(s) checked — ${FAIL_COUNT} fail(s), ${WARN_COUNT} warning(s)"

[[ "$FAIL_COUNT" -eq 0 ]]
