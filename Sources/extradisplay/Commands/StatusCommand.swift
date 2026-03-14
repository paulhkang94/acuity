import ArgumentParser
import CoreGraphics
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show detailed HiDPI and DDC/CI status for each connected external display."
    )

    func run() throws {
        let displays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

        if displays.isEmpty {
            print("⚠ No external displays detected.")
            return
        }

        for display in displays {
            printDisplayStatus(display)
        }
    }

    // MARK: - Per-display output

    private func printDisplayStatus(_ display: DisplayInfo) {
        let idStr = String(format: "%04x:%04x", display.vendorID, display.productID)

        // Header line: Name [vendorID:productID] — ConnectionType
        print("\(display.name) [\(idStr)] — \(display.connectionType)")

        // Resolution + refresh rate
        let (modeStr, refreshHz) = currentModeDescription(display)
        print("  Resolution:  \(display.nativeWidth)×\(display.nativeHeight)\(refreshHz.map { " @ \($0)Hz" } ?? "")")

        // HiDPI override plist
        let plistExists = PlistWriter.exists(vendorID: display.vendorID, productID: display.productID)
        let plistIndicator = plistExists ? "✓" : "✗"
        let plistLabel = plistExists ? "installed" : "not installed"
        print("  HiDPI plist: \(plistIndicator) \(plistLabel)")

        // Current display mode
        print("  Current mode: \(modeStr)")

        // DDC/CI capability
        let ddcSupported = IOAVServiceBridge.isAvailable() && probeDDC(display)
        let ddcIndicator = ddcSupported ? "✓" : "✗"
        let ddcLabel = ddcSupported ? "supported" : "not available"
        print("  DDC/CI:      \(ddcIndicator) \(ddcLabel)")

        print("")
    }

    // MARK: - Display mode detection

    /// Returns a human-readable mode description and the refresh rate in Hz (if readable).
    ///
    /// Queries `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`
    /// so that HiDPI (scaled) modes appear alongside standard modes. The active mode is matched
    /// against the current display bounds to determine if HiDPI is in use.
    private func currentModeDescription(_ display: DisplayInfo) -> (description: String, hz: Int?) {
        let options: CFDictionary = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true as CFBoolean,
        ] as CFDictionary

        guard
            let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode],
            let activeMode = modes.first(where: { $0.isUsableForDesktopGUI() && isCurrentMode($0, display: display) })
        else {
            return ("unknown", nil)
        }

        let hz = Int(activeMode.refreshRate.rounded())
        let refreshStr = hz > 0 ? " @ \(hz)Hz" : ""

        // A mode is HiDPI when its pixel dimensions exceed its point dimensions
        let isHiDPI = activeMode.pixelWidth > activeMode.width || activeMode.pixelHeight > activeMode.height
        if isHiDPI {
            let logicalW = activeMode.width
            let logicalH = activeMode.height
            let scale = activeMode.pixelWidth / activeMode.width
            let modeDesc = "✓ HiDPI active (\(logicalW)×\(logicalH) @\(scale)×\(refreshStr))"
            return (modeDesc, hz > 0 ? hz : nil)
        } else {
            let modeDesc = "✗ Standard (\(activeMode.width)×\(activeMode.height)\(refreshStr))"
            return (modeDesc, hz > 0 ? hz : nil)
        }
    }

    /// Returns true when the given mode matches the display's current pixel dimensions.
    private func isCurrentMode(_ mode: CGDisplayMode, display: DisplayInfo) -> Bool {
        mode.pixelWidth == display.nativeWidth && mode.pixelHeight == display.nativeHeight
    }

    // MARK: - DDC probe

    /// Attempts a DDC brightness read to confirm DDC/CI is responsive.
    /// A failure (any error) is treated as "not supported" rather than a fatal error.
    private func probeDDC(_ display: DisplayInfo) -> Bool {
        do {
            let bridge = try IOAVServiceBridge(displayID: display.displayID)
            _ = try bridge.readDDC(displayID: display.displayID, vcpCode: .brightness)
            return true
        } catch {
            return false
        }
    }
}
