#!/usr/bin/env bash
# One-shot install: build + assemble app bundle + install CLI + register LaunchAgent.
# No sudo needed on Apple Silicon (/opt/homebrew/bin/ and ~/Applications/ are user-writable).

set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
    echo "error: do not run install.sh with sudo." >&2
    echo "  /opt/homebrew/bin/ is user-writable on Apple Silicon." >&2
    echo "  Run: bash scripts/install.sh" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "▶ Building..."
swift build -c release

echo "▶ Assembling app bundle..."
bash scripts/build-app.sh

echo "▶ Installing CLI binary..."
if [[ -d /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    mkdir -p "$HOME/.local/bin"
    INSTALL_DIR="$HOME/.local/bin"
fi
# rm first — can't overwrite root-owned file even if directory is user-writable
rm -f "$INSTALL_DIR/extradisplay"
cp .build/release/extradisplay "$INSTALL_DIR/extradisplay"
echo "  ✓ CLI: $INSTALL_DIR/extradisplay"

echo "▶ Installing app bundle..."
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/ExtradisplayApp.app"
cp -r build/ExtradisplayApp.app "$HOME/Applications/ExtradisplayApp.app"
echo "  ✓ App: $HOME/Applications/ExtradisplayApp.app"

echo "▶ Registering LaunchAgent..."
# Uninstall first (idempotent) then install fresh
"$INSTALL_DIR/extradisplay" uninstall 2>/dev/null || true
"$INSTALL_DIR/extradisplay" install
