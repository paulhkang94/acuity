#!/usr/bin/env bash
# Sign Acuity.app with a Developer ID Application certificate.
# Must be run AFTER scripts/build-app.sh.
#
# Usage (local):
#   APP_PATH=/path/to/build/Acuity.app bash scripts/sign-app.sh
#
# In CI, APP_PATH is set by the workflow env before this script runs.
# The signing identity is resolved from the keychain imported earlier in the job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$REPO_ROOT/build/Acuity.app}"
IDENTITY="Developer ID Application"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  echo "  Run 'swift build -c release && bash scripts/build-app.sh' first." >&2
  exit 1
fi

# ── Step 1: Sign any nested binaries first (inside-out) ─────────────────────
# Acuity.app currently contains only one binary (extradisplay). There are no
# embedded frameworks or helper tools, so the loop below is a no-op in practice.
# It's included so adding nested binaries in the future doesn't break signing.
find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \) | while read -r nested; do
  echo "  Signing nested: $nested"
  codesign --force --sign "$IDENTITY" \
    --timestamp \
    --options runtime \
    "$nested"
done

# ── Step 2: Sign the app bundle ──────────────────────────────────────────────
echo "▶ Signing $APP_PATH ..."
codesign --force --sign "$IDENTITY" \
  --timestamp \
  --options runtime \
  "$APP_PATH"

# ── Step 3: Verify ───────────────────────────────────────────────────────────
echo "▶ Verifying signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "✓ Signature valid"

codesign -dv "$APP_PATH" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Signature size|Authority)" || true
