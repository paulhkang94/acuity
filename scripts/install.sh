#!/usr/bin/env bash
# Install extradisplay binary system-wide.
#
# Usage — no sudo needed on Apple Silicon (/opt/homebrew/bin/ is user-owned):
#   bash scripts/install.sh
#
# Never run with sudo: swift build as root makes .build/ root-owned (breaks
# future builds), and a root-owned binary with AppKit linked is SIGKILLed
# by macOS Sequoia when run by a non-root user.

set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
    echo "error: do not run install.sh with sudo." >&2
    echo "  /opt/homebrew/bin/ is user-writable on Apple Silicon." >&2
    echo "  Run: bash scripts/install.sh" >&2
    exit 1
fi

echo "Building..."
swift build -c release

if [[ -d /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    mkdir -p /usr/local/bin
    INSTALL_DIR="/usr/local/bin"
fi

# Remove first so cp creates a fresh user-owned file.
# (Can't overwrite a root-owned file even if the directory is ours.)
rm -f "$INSTALL_DIR/extradisplay"
cp .build/release/extradisplay "$INSTALL_DIR/extradisplay"

echo "✓ extradisplay installed to $INSTALL_DIR/extradisplay"
echo ""
echo "Next steps:"
echo "  sudo extradisplay enable --all   # write HiDPI overrides (needs root)"
echo "  extradisplay install              # register LaunchAgent (no sudo)"
