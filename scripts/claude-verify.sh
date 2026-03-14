#!/usr/bin/env bash
# Tiered verification for extradisplay (Swift Package Manager, macOS CLI + menubar).
# Usage: scripts/claude-verify.sh [--build|--test|--python-test|--lint|--all]
#
# Tiers:
#   --build        swift build -c release (~10-30s)
#   --test         swift test (~15-60s)
#   --python-test  pytest pytests/ (~5s)
#   --lint         swiftformat --lint (~5s, advisory)
#   --all          build → test → python-test → lint (default)
#
# NOTE: This repo uses Swift Package Manager, not xcodebuild.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/cl-version.sh" 2>/dev/null || CL_JSONL_VERSION=3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TIER="${1:---all}"
SECONDS=0

_SESSION_ID=""
[[ -f "$REPO_ROOT/.claude/memory/.session_id" ]] && _SESSION_ID=$(cat "$REPO_ROOT/.claude/memory/.session_id" 2>/dev/null) || true

log_verify() {
  [[ "${LOOP_METRICS:-1}" == "0" ]] && return 0
  local tier="$1" result="$2" elapsed="$3"
  local f="$REPO_ROOT/.claude/memory/metrics.jsonl"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$(dirname "$f")"
  printf '{"v":%s,"timestamp":"%s","repo":"extradisplay","event":"verify","tier":"%s","result":"%s","elapsed_s":%s}\n' \
    "$CL_JSONL_VERSION" "$ts" "$tier" "$result" "$elapsed" >> "$f"
}

[[ -z "${LOOP_VERIFY_NESTED:-}" ]] && trap 'log_verify "$TIER" "$([ $? -eq 0 ] && echo pass || echo fail)" "$SECONDS"' EXIT

case "$TIER" in
  --build)
    echo "--- swift build ---"
    swift build -c release 2>&1 | tail -8
    echo "--- build: ${SECONDS}s ---"
    ;;

  --test)
    echo "--- swift test ---"
    swift test 2>&1 | tail -12
    echo "--- test: ${SECONDS}s ---"
    ;;

  --python-test)
    echo "--- python tests ---"
    python3 -m pytest pytests/ -q 2>&1 | tail -5
    echo "--- python: ${SECONDS}s ---"
    ;;

  --lint)
    echo "--- swiftformat lint ---"
    if command -v swiftformat >/dev/null 2>&1; then
      swiftformat --lint Sources/ Tests/ 2>&1 | tail -8 || true  # advisory
    else
      echo "  swiftformat not installed — skipping"
    fi
    echo "--- lint: ${SECONDS}s ---"
    ;;

  --all)
    echo "=== extradisplay verify ==="
    export LOOP_VERIFY_NESTED=1
    bash "$0" --build        || { echo "FAILED: build (${SECONDS}s)"; exit 1; }
    bash "$0" --test         || { echo "FAILED: swift test (${SECONDS}s)"; exit 1; }
    bash "$0" --python-test  || { echo "FAILED: python tests (${SECONDS}s)"; exit 1; }
    bash "$0" --lint         || true
    echo "=== PASSED (${SECONDS}s) ==="
    ;;

  *)
    echo "Usage: $0 [--build|--test|--python-test|--lint|--all]"
    exit 1
    ;;
esac
