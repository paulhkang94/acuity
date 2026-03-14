#!/usr/bin/env bash
# Install extradisplay binary system-wide.
#
# Usage (correct — build as user, copy needs sudo):
#   swift build -c release
#   sudo bash scripts/install.sh
#
# DO NOT run `sudo bash scripts/install.sh` without building first.
# `swift build` must run as the current user — running it as root makes
# .build/ root-owned, which blocks future user builds.

set -euo pipefail

# Refuse to build as root. Build artifacts must be user-owned.
if [[ "$(id -u)" == "0" ]]; then
    # Already root (via sudo) — copy only, don't build.
    COPY_ONLY=1
else
    COPY_ONLY=0
fi

if [[ "$COPY_ONLY" == "0" ]]; then
    echo "Building..."
    swift build -c release
fi

if [[ -d /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    mkdir -p /usr/local/bin
    INSTALL_DIR="/usr/local/bin"
fi

cp .build/release/extradisplay "$INSTALL_DIR/extradisplay"

echo "✓ extradisplay installed to $INSTALL_DIR/extradisplay"
echo ""
echo "Next steps:"
echo "  sudo extradisplay enable --all   # write HiDPI overrides (needs root)"
echo "  extradisplay install              # register LaunchAgent (no sudo)"
