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
    /// Reads the genuinely active mode via `CGDisplayCopyDisplayMode` rather than
    /// scanning all modes and guessing — multiple modes share the same pixel
    /// dimensions (a 2560-pixel framebuffer is both a 1× 2560×1440 mode and a 2×
    /// "looks like 1280×720" mode), so matching by size picked an arbitrary one.
    private func currentModeDescription(_ display: DisplayInfo) -> (description: String, hz: Int?) {
        guard let activeMode = CGDisplayCopyDisplayMode(display.displayID) else {
            return ("unknown", nil)
        }

        let hz = Int(activeMode.refreshRate.rounded())
        let desc = StatusCommand.describeMode(
            pointWidth: activeMode.width,
            pointHeight: activeMode.height,
            pixelWidth: activeMode.pixelWidth,
            pixelHeight: activeMode.pixelHeight,
            hz: hz > 0 ? hz : nil
        )
        return (desc, hz > 0 ? hz : nil)
    }

    /// Pure, testable formatter for the current-mode line.
    ///
    /// A mode is HiDPI when its framebuffer (pixels) exceeds its logical size
    /// (points); the scale factor is pixels ÷ points.
    static func describeMode(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        hz: Int?
    ) -> String {
        let refreshStr = hz.map { " @ \($0)Hz" } ?? ""
        let isHiDPI = pixelWidth > pointWidth || pixelHeight > pointHeight
        if isHiDPI {
            let scale = pointWidth > 0 ? pixelWidth / pointWidth : 1
            return "✓ HiDPI active (\(pointWidth)×\(pointHeight) @\(scale)×\(refreshStr))"
        } else {
            return "✗ Standard (\(pointWidth)×\(pointHeight)\(refreshStr))"
        }
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
