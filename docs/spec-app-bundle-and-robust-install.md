# Spec: App Bundle + Robust Install
**Goal:** Make `extradisplay install` a one-time operation that permanently auto-starts the menubar at login.
**Verify:** `scripts/claude-verify.sh --all` must pass before committing.

---

## Root Cause (confirmed)

NSApplication cannot connect to WindowServer when spawned by launchd from a **bare binary** (no `.app` bundle / Info.plist). macOS requires an app bundle context to grant WindowServer access to launchd-spawned GUI processes. This is why `extradisplay start` exits EX_CONFIG (78) from the LaunchAgent but works from Terminal.

**The fix:** Create `ExtradisplayApp.app` — a thin app bundle wrapper around the existing binary. The LaunchAgent points to the binary *inside* the bundle. macOS loads the bundle's `Info.plist`, NSApplication gets WindowServer access, and the menubar starts correctly at every login.

---

## Files to Create

### 1. `Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.extradisplay.app</string>
    <key>CFBundleName</key>
    <string>extradisplay</string>
    <key>CFBundleExecutable</key>
    <string>extradisplay</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
```

### 2. `scripts/build-app.sh`

```bash
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
```

### 3. `scripts/install.sh` (full replacement)

```bash
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
```

---

## Files to Modify

### 4. `Sources/extradisplay/main.swift`

Replace `ExtraDisplay.main()` with:

```swift
import Foundation

// When launched from inside an app bundle (e.g., via LaunchAgent pointing to
// ~/Applications/ExtradisplayApp.app/Contents/MacOS/extradisplay),
// default to `start` so the menubar launches automatically.
// All explicit subcommand invocations (e.g., `extradisplay list`) are unaffected.
var args = CommandLine.arguments
if args.count == 1, Bundle.main.bundlePath.hasSuffix(".app") {
    args.append("start")
}
ExtraDisplay.main(args)
```

### 5. `Sources/extradisplay/Daemon/AgentManager.swift`

**a)** Add a `command` parameter to `install()` and `buildPlist()`:

```swift
public static func install(executablePath: URL, command: String = "daemon") throws {
    ...
    let plistContent = buildPlist(executablePath: executablePath, command: command)
    ...
}

private static func buildPlist(executablePath: URL, command: String = "daemon") -> String {
    return """
    ...
        <key>ProgramArguments</key>
        <array>
            <string>\(executablePath.path)</string>
            <string>\(command)</string>
        </array>
    ...
    """
}
```

**b)** Keep `buildPlist` accepting command param; update the existing `<string>daemon</string>` line to use the parameter.

### 6. `Sources/extradisplay/Commands/InstallCommand.swift`

Replace the `AgentManager.install(executablePath:)` call with logic that picks the app bundle if available:

```swift
// Prefer the app bundle binary (enables NSApplication / menubar via launchd).
// Fall back to the CLI binary in daemon mode if the bundle isn't installed yet.
let bundleBinary = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/ExtradisplayApp.app/Contents/MacOS/extradisplay")

let (launchPath, launchCommand): (URL, String) = {
    if FileManager.default.fileExists(atPath: bundleBinary.path) {
        return (bundleBinary, "start")
    } else {
        return (executableURL, "daemon")
    }
}()

try AgentManager.install(executablePath: launchPath, command: launchCommand)
let modeStr = launchCommand == "start" ? "menubar (start)" : "headless (daemon)"
print("  ✓ LaunchAgent installed [\(modeStr)]: \(AgentManager.plistPath.path)")
```

---

## Tests to Add

### `Tests/extradisplayTests/AppBundleTests.swift`

```swift
class AppBundleTests: XCTestCase {
    func test_infoPlistExists() {
        let plist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Tests/extradisplayTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path),
                      "Resources/Info.plist must exist for app bundle")
    }

    func test_infoPlistHasRequiredKeys() throws {
        let plist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        XCTAssertNotNil(dict["CFBundleIdentifier"])
        XCTAssertEqual(dict["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertTrue(dict["LSUIElement"] as? Bool ?? false,
                      "LSUIElement must be YES to hide from Dock")
    }
}
```

---

## Verify Gate

After all changes, this must pass:

```bash
cd /Users/pkang/repos/extradisplay
scripts/claude-verify.sh --all
```

Expected:
- `swift build -c release` → clean
- `swift test` → all 42+ tests pass (including new AppBundleTests)
- `python3 -m pytest pytests/ -q` → 9 tests pass
- `bash scripts/build-app.sh` → `build/ExtradisplayApp.app` assembled

---

## Smoke Test

```bash
# Uninstall old, install fresh
extradisplay uninstall 2>/dev/null || true
bash scripts/install.sh

# Verify menubar is running
sleep 3
launchctl list com.extradisplay.agent
cat /tmp/extradisplay.log | tail -5
# Should show: "[extradisplay] ReconfigurationWatcher started."
# AND:         "[extradisplay] BrightnessKeyInterceptor: listening for brightness keys."
# (NOT just: "[extradisplay] daemon starting")

# Screenshot the menubar
screencapture -R "960,0,960,28" -x /tmp/final_smoke.png
```

The screenshot must show the monitor icon (⊟) in the system tray.

---

## Commit Message

```
feat: app bundle wrapper + robust one-shot install

NSApplication cannot connect to WindowServer when spawned by launchd
from a bare binary (no .app bundle / Info.plist). This caused
extradisplay start to exit EX_CONFIG (78) from the LaunchAgent.

Fix: create ExtradisplayApp.app — a thin bundle wrapping the existing
binary. The LaunchAgent points to the binary inside the bundle; macOS
loads the bundle's Info.plist, NSApplication gets WindowServer access,
and the menubar starts at every login without manual intervention.

Changes:
- Resources/Info.plist: app bundle metadata (LSUIElement, NSPrincipalClass)
- scripts/build-app.sh: assembles the .app from the compiled binary
- scripts/install.sh: one-shot build+bundle+install+register, no sudo
- main.swift: auto-selects `start` when run from inside .app bundle
- AgentManager: `command` parameter (start vs daemon)
- InstallCommand: uses app bundle binary + start when bundle is installed
- AppBundleTests: verify Info.plist exists and has required keys

After: `bash scripts/install.sh` is the only command needed, ever.
```
