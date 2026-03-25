# P0 Menubar Implementation Spec
**Repo:** /Users/pkang/repos/extradisplay
**Verify:** `scripts/claude-verify.sh --all` must be green before committing

---

## Goal
Implement three P0 features as a single atomic commit:
1. `acuity start` — menubar app (NSStatusItem + NSMenu, per-display brightness sliders + input picker + HiDPI toggle)
2. Keyboard brightness keys — IOHIDManager intercepts Fn-brightness keys → DDC on all external monitors
3. OSD overlay — BezelServices wrapper shows macOS-native brightness indicator on DDC change

All changes must pass `scripts/claude-verify.sh --all` (swift build + swift test + python tests).

---

## Architecture

### Protocol for testability
Before writing any new code, add `protocol DDCControlling` to `Sources/extradisplay/DDC/DDCController.swift`:

```swift
public protocol DDCControlling {
    func setBrightness(_ value: Int, display: DisplayInfo) throws
    func getBrightness(display: DisplayInfo) throws -> Int
    func setContrast(_ value: Int, display: DisplayInfo) throws
    func setInput(_ source: InputSource, display: DisplayInfo) throws
}
```

Make `DDCController` conform to it. Tests inject `MockDDCController`.

---

## Files to Create

### 1. `Sources/extradisplay/Menubar/StatusMenuController.swift`

```swift
import AppKit
import Foundation

/// Owns the NSStatusItem and rebuilds the menu on display change events.
/// Injected with DDCControlling for testability.
public final class StatusMenuController: NSObject {
    private let statusItem: NSStatusItem
    private let ddc: DDCControlling
    private var displays: [DisplayInfo] = []

    public init(ddc: DDCControlling) { ... }

    /// Called by StartCommand after NSApplication is running.
    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "extradisplay")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    /// Rebuilds the NSMenu from current DisplayEnumerator.allDisplays()
    public func rebuildMenu() { ... }
}
```

Menu structure (rebuild on every open via `menuWillOpen`):
```
● Display 1: <name> [HiDPI ✓ / ✗]
  Brightness   [custom NSSlider view, 0-100, steps DDC on change]
  Input: <current> ▶  [submenu: VGA 1 / DisplayPort 1 / DisplayPort 2 / HDMI 1 / HDMI 2 / USB-C]
─────────────────────
● Display 2: <name> [HiDPI ✓ / ✗]
  Brightness   [slider]
  Input: <current> ▶
─────────────────────
Enable HiDPI on All...   [calls: sudo acuity enable --all — shows install prompt if not root]
─────────────────────
Quit
```

### 2. `Sources/extradisplay/Menubar/BrightnessSliderView.swift`

Custom `NSView` used as `NSMenuItem.view` for the brightness row.
- `NSSlider` (minValue: 0, maxValue: 100, intValue from DDC)
- Debounce DDC writes: only call DDC after slider is idle for 150ms (use `DispatchWorkItem`)
- Label "☀" on left, "☀" larger on right

### 3. `Sources/extradisplay/Menubar/DisplayMenuItem.swift`

`NSMenuItem` subclass (or factory) that creates the per-display section:
- Header item: bold display name + HiDPI badge (non-clickable, `isEnabled = false`)
- Brightness item with `BrightnessSliderView`
- Input submenu

### 4. `Sources/extradisplay/HID/BrightnessKeyInterceptor.swift`

```swift
import IOKit.hid
import Foundation

/// Intercepts system brightness key events (consumer usage page) and routes to DDC.
public final class BrightnessKeyInterceptor {
    private var manager: IOHIDManager?
    private let ddc: DDCControlling
    private let step = 10  // brightness delta per key press

    public init(ddc: DDCControlling) { self.ddc = ddc }

    /// Call after NSApplication is running. Returns false if IOHIDManager setup fails.
    @discardableResult
    public func start() -> Bool { ... }
    public func stop() { ... }
}
```

Implementation notes:
- Use `IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone)`
- Match on `kHIDPage_Consumer` / `kHIDUsage_Csmr_BrightnessDecrement` (0x70) and `kHIDUsage_Csmr_BrightnessIncrement` (0x6F)
- In the callback: get current brightness via DDC, clamp ±step, set new value
- Call `IOHIDManagerSetInputValueMatchingMultiple` with the two usages
- Schedule on `CFRunLoopGetMain()`
- If IOHIDManager creation fails (e.g., no Accessibility permission), log a warning and return false — don't crash

### 5. `Sources/extradisplay/OSD/BezelOverlay.swift`

```swift
import Foundation

/// Wraps the private BezelServices framework to show the native macOS brightness OSD.
/// Falls back to no-op if BezelServices is unavailable (e.g., future macOS versions).
public struct BezelOverlay {
    /// Show the standard brightness bezel at `level` (0.0–1.0).
    public static func showBrightness(_ level: Float) { ... }
}
```

Implementation:
```swift
private typealias BSDoGraphicFn = @convention(c) (Int, UInt32, UInt32, Float, Int) -> Void

private let _handle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/BezelServices", RTLD_GLOBAL)
}()

public static func showBrightness(_ level: Float) {
    guard let handle = _handle,
          let sym = dlsym(handle, "BSDoGraphicWithMeterAndTimeout") else { return }
    let fn = unsafeBitCast(sym, to: BSDoGraphicFn.self)
    fn(0, 0x00000007, 0, level, 1)  // graphic type 7 = brightness
}
```

### 6. `Sources/extradisplay/Commands/StartCommand.swift`

```swift
import ArgumentParser
import AppKit
import Foundation

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the menubar app (runs in background, re-applies HiDPI on reconnect)."
    )

    func run() throws {
        // Detach from terminal so the process doesn't hold the shell
        setsid()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let ddc = DDCController()
        let controller = StatusMenuController(ddc: ddc)
        let keyInterceptor = BrightnessKeyInterceptor(ddc: ddc)

        // Also start the display reconfiguration watcher (same as `acuity daemon`)
        let watcher = ReconfigurationWatcher()
        try watcher.start()

        // Wire OSD into key interceptor (BrightnessKeyInterceptor calls BezelOverlay.showBrightness after DDC set)

        DispatchQueue.main.async {
            controller.setup()
            keyInterceptor.start()
        }

        app.run()
    }
}
```

Register in `ExtraDisplay.swift`: add `StartCommand.self` to the `subcommands` array.

### 7. Update `LaunchAgent/com.acuity.agent.plist`

Change `ProgramArguments` from:
```xml
<string>daemon</string>
```
to:
```xml
<string>start</string>
```

This replaces the headless daemon with the menubar app (which includes daemon functionality).

---

## Tests to Write

### `Tests/extradisplayTests/StatusMenuControllerTests.swift`

```swift
class StatusMenuControllerTests: XCTestCase {
    func test_rebuildMenu_withTwoDisplays_createsTwoSections() { ... }
    func test_rebuildMenu_withNoDisplays_showsOnlyQuit() { ... }
    func test_brightnessSlider_debounce_doesNotCallDDCOnEveryTick() { ... }
}
```
Use `MockDDCController` — `DDCController` is **never** instantiated in tests.

### `Tests/extradisplayTests/BrightnessKeyInterceptorTests.swift`

```swift
class BrightnessKeyInterceptorTests: XCTestCase {
    func test_start_withMockDDC_doesNotThrow() { ... }
    func test_brightnessStep_clampedAt100() { ... }
    func test_brightnessStep_clampedAt0() { ... }
}
```

### `Tests/extradisplayTests/BezelOverlayTests.swift`

```swift
class BezelOverlayTests: XCTestCase {
    // BezelServices may not be available in CI — test that showBrightness never crashes
    func test_showBrightness_doesNotCrash_whenBezelServicesAbsent() {
        // Should be a no-op, not a crash
        BezelOverlay.showBrightness(0.5)
    }
    func test_showBrightness_clampedLevel_doesNotCrash() {
        BezelOverlay.showBrightness(-0.1)
        BezelOverlay.showBrightness(1.5)
    }
}
```

---

## Package.swift Changes

Add `AppKit` linker setting to the main target:
```swift
linkerSettings: [
    .linkedFramework("IOKit"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("AppKit"),
]
```

---

## Verification Gate

After implementation, the following must all pass:

```bash
cd /Users/pkang/repos/extradisplay
scripts/claude-verify.sh --all
```

Expected:
- `swift build -c release` → build complete, no errors
- `swift test` → all existing 19 tests + new menubar/HID/OSD tests pass
- `python3 -m pytest pytests/ -q` → 9 tests pass
- swiftformat lint → no violations

---

## Visual Smoke Test (run after verify passes)

```bash
# Build and launch menubar
swift build -c release
.build/release/acuity start &
sleep 2

# Screenshot to verify menubar icon appeared
screencapture -x /tmp/menubar_smoke.png
open /tmp/menubar_smoke.png

# Kill the menubar process
pkill -f "acuity start"
```

The screenshot should show the extradisplay icon in the macOS menubar (monitor icon, template image).

---

## Commit Message

```
feat(P0): menubar app, keyboard brightness keys, OSD overlay

- StartCommand: NSApplication in .accessory mode (no Dock icon)
  Detaches from terminal via setsid(). Starts ReconfigurationWatcher
  + BrightnessKeyInterceptor on main queue.

- StatusMenuController: NSStatusItem with per-display sections.
  BrightnessSliderView with 150ms debounce for DDC writes.
  Input source submenu (VGA/DP/HDMI/USB-C).
  HiDPI status badge in display header.

- BrightnessKeyInterceptor: IOHIDManager on consumer usage page.
  Intercepts kHIDUsage_Csmr_BrightnessDecrement/Increment.
  Routes to DDC ±10 brightness, calls BezelOverlay.showBrightness.
  Graceful no-op if Accessibility permission not granted.

- BezelOverlay: dlopen/dlsym wrapper for BezelServices private
  framework. Shows native macOS brightness OSD. No-op fallback
  if framework unavailable.

- protocol DDCControlling + MockDDCController for all test isolation.

- LaunchAgent: updated ProgramArguments to `start` (replaces daemon).

Tests: +N Swift tests. All existing 28 tests still pass.
```
