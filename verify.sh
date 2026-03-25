#!/usr/bin/env bash
# Full verification pipeline for extradisplay / Acuity.
# Usage: bash verify.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "=== Acuity (extradisplay) Verification ==="

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

if [[ ! -f "build/Acuity.app/Contents/MacOS/extradisplay" ]]; then
    echo "✗ Bundle binary missing: build/Acuity.app/Contents/MacOS/extradisplay"
    exit 1
fi
echo "✓ build/Acuity.app/Contents/MacOS/extradisplay exists"

echo ""
echo "✓ All checks passed"
