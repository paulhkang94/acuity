#!/usr/bin/env bash
# Full verification pipeline for Acuity.
# Usage: bash verify.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "=== Acuity Verification ==="

echo ""
echo "--- swift build (debug) ---"
swift build
echo "✓ Debug build passed"

echo ""
echo "--- swift test ---"
swift test
echo "✓ Tests passed"

echo ""
echo "--- App bundle ---"
swift build -c release
bash scripts/build-app.sh

if [[ ! -f "build/Acuity.app/Contents/MacOS/acuity" ]]; then
    echo "✗ Bundle binary missing: build/Acuity.app/Contents/MacOS/acuity"
    exit 1
fi
echo "✓ build/Acuity.app/Contents/MacOS/acuity exists"

echo ""
echo "✓ All checks passed"
