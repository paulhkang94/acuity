#!/usr/bin/env bash
# Assembles ExtradisplayApp.app from the compiled extradisplay binary.
# Must be run AFTER swift build -c release.
# Output: build/ExtradisplayApp.app/

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPO_ROOT/.build/release/extradisplay"
APP_OUT="$REPO_ROOT/build/ExtradisplayApp.app"
CONTENTS="$APP_OUT/Contents"

[[ -f "$BINARY" ]] || { echo "error: build binary first: swift build -c release"; exit 1; }

mkdir -p "$CONTENTS/MacOS"
cp "$BINARY" "$CONTENTS/MacOS/extradisplay"
cp "$REPO_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc code sign so Gatekeeper doesn't block it
codesign --force --sign - "$APP_OUT" 2>/dev/null || true

echo "✓ Built $APP_OUT"
