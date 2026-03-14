#!/usr/bin/env bash
set -euo pipefail

BINARY=/usr/local/bin/extradisplay
AGENT_LABEL="com.extradisplay.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
OVERRIDES_DIR="/Library/Displays/Contents/Resources/Overrides"

# Parse flags
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

echo "Uninstalling extradisplay..."

# 1. Unload and remove the LaunchAgent
if launchctl list "$AGENT_LABEL" &>/dev/null; then
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    echo "  ✓ LaunchAgent unloaded."
fi

if [ -f "$AGENT_PLIST" ]; then
    rm -f "$AGENT_PLIST"
    echo "  ✓ LaunchAgent plist removed: $AGENT_PLIST"
else
    echo "  ℹ LaunchAgent plist not found — skipping."
fi

# 2. Remove the binary
if [ -f "$BINARY" ]; then
    sudo rm -f "$BINARY"
    echo "  ✓ Binary removed: $BINARY"
else
    echo "  ℹ Binary not found at $BINARY — skipping."
fi

# 3. Optionally remove display override plists
if [ "$CLEAN" -eq 1 ]; then
    echo ""
    echo "  Removing HiDPI display overrides (--clean)..."
    if [ -d "$OVERRIDES_DIR" ]; then
        removed=0
        while IFS= read -r -d '' plist; do
            sudo rm -f "$plist"
            removed=$((removed + 1))
        done < <(find "$OVERRIDES_DIR" -name "DisplayProductID-*" -print0 2>/dev/null)

        # Clean up empty vendor directories
        find "$OVERRIDES_DIR" -name "DisplayVendorID-*" -type d -empty -exec sudo rmdir {} + 2>/dev/null || true

        echo "  ✓ Removed $removed override plist(s)."
    else
        echo "  ℹ Overrides directory not found — skipping."
    fi
fi

echo ""
echo "✓ Uninstall complete. Reboot to deactivate any active HiDPI overrides."
