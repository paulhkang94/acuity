#!/usr/bin/env bash
set -euo pipefail

# Build extradisplay
swift build -c release

# Copy to /usr/local/bin
sudo cp .build/release/extradisplay /usr/local/bin/extradisplay

echo "✓ extradisplay installed to /usr/local/bin/extradisplay"
echo "Run: sudo extradisplay enable --all"
echo "Then reboot to activate HiDPI modes."
