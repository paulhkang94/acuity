#!/usr/bin/env bash
set -euo pipefail

# Build extradisplay
swift build -c release

# Copy to /usr/local/bin (Intel) or /opt/homebrew/bin (Apple Silicon)
if [[ -d /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    sudo mkdir -p /usr/local/bin
    INSTALL_DIR="/usr/local/bin"
fi
sudo cp .build/release/extradisplay "$INSTALL_DIR/extradisplay"

echo "✓ extradisplay installed to $INSTALL_DIR/extradisplay"
echo "Run: sudo extradisplay enable --all"
echo "Then reboot to activate HiDPI modes."
