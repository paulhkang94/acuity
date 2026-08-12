#!/usr/bin/env bash
# Pre-commit gate for Acuity (acu-011).
#
# Commit-time checks are scoped to STAGED files and kept fast on purpose -
# the full pipeline (swift test + release bundle) lives in verify.sh and CI.
# Install shim (idempotent):
#   printf '#!/usr/bin/env bash\nexec "$(git rev-parse --show-toplevel)/scripts/pre-commit-hook.sh" "$@"\n' \
#     > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1

staged() {
  git diff --cached --name-only --diff-filter=ACM | grep -E "$1" || true
}

FAIL=0

# ── shellcheck on staged .sh (same warning floor as the template fleet) ─────
STAGED_SH="$(staged '\.sh$')"
if [[ -n "$STAGED_SH" ]] && command -v shellcheck >/dev/null 2>&1; then
  echo "pre-commit: shellcheck (staged .sh)..."
  # shellcheck disable=SC2086
  if ! shellcheck --severity=warning $STAGED_SH; then
    echo "✗ shellcheck failed"
    FAIL=1
  fi
fi

# ── ruff on staged .py ──────────────────────────────────────────────────────
STAGED_PY="$(staged '\.py$')"
if [[ -n "$STAGED_PY" ]] && command -v ruff >/dev/null 2>&1; then
  echo "pre-commit: ruff (staged .py)..."
  # shellcheck disable=SC2086
  if ! ruff check $STAGED_PY; then
    echo "✗ ruff failed"
    FAIL=1
  fi
fi

# ── swift build when Swift sources are staged (compile gate, not full test) ─
STAGED_SWIFT="$(staged '\.swift$|Package\.(swift|resolved)$')"
if [[ -n "$STAGED_SWIFT" ]]; then
  echo "pre-commit: swift build (staged Swift changes)..."
  BUILD=(swift build)
  # Demote below UI priority - all-core bursts freeze WindowServer.
  if command -v taskpolicy >/dev/null 2>&1; then
    BUILD=(taskpolicy -c utility swift build)
  fi
  if ! "${BUILD[@]}"; then
    echo "✗ swift build failed"
    FAIL=1
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "pre-commit: blocked. Fix the failures above (full pipeline: bash verify.sh)."
  exit 1
fi
echo "pre-commit: ok"
exit 0
