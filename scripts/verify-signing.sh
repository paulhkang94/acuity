#!/usr/bin/env bash
# Verify that an app bundle is properly signed and Gatekeeper-accepted.
#
# Usage:
#   bash scripts/verify-signing.sh /path/to/Acuity.app
#
# Checks:
#   1. codesign --verify --deep --strict  (signature integrity)
#   2. codesign -dv                       (prints signing identity details)
#   3. spctl --assess                     (Gatekeeper acceptance)
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more checks failed

set -euo pipefail

APP_PATH="${1:-}"

if [[ -z "$APP_PATH" ]]; then
  echo "Usage: $0 /path/to/Acuity.app" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: not a directory: $APP_PATH" >&2
  exit 1
fi

FAILED=0

# ── Check 1: Signature integrity ────────────────────────────────────────────
echo "▶ Verifying signature integrity..."
if codesign --verify --deep --strict "$APP_PATH" 2>&1; then
  echo "✓ codesign --verify --deep --strict passed"
else
  echo "✗ codesign verification FAILED" >&2
  FAILED=1
fi

# ── Check 2: Signing details ─────────────────────────────────────────────────
echo ""
echo "▶ Signing details:"
codesign -dv "$APP_PATH" 2>&1 || true

# ── Check 3: Gatekeeper acceptance ──────────────────────────────────────────
echo ""
echo "▶ Checking Gatekeeper acceptance..."
if spctl --assess --type execute "$APP_PATH" 2>/dev/null; then
  echo "✓ Gatekeeper ACCEPTS the app"
else
  VERBOSE=$(spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 || echo "")
  echo "✗ Gatekeeper REJECTS the app" >&2
  echo "$VERBOSE" >&2
  FAILED=1
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "✓ All signing checks passed"
else
  echo "✗ One or more signing checks FAILED" >&2
  exit 1
fi
