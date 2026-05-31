import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// MARK: - DisplayModeDescriptor

/// A CoreGraphics-free snapshot of a display mode's dimensions and flags.
///
/// Keeps `selectNativeResolution` pure and testable against captured hardware
/// data instead of requiring a live `CGDisplayMode`.
struct DisplayModeDescriptor {
    /// Physical framebuffer width in pixels.
    let pixelWidth: Int
    /// Physical framebuffer height in pixels.
    let pixelHeight: Int
    /// Logical width in points (`CGDisplayMode.width`).
    let pointWidth: Int
    /// IOKit mode flags (`CGDisplayMode.ioFlags`).
    let ioFlags: UInt32
}

// MARK: - DisplayEnumerator

/// Enumerates connected displays using CGDisplay and IOKit.
public struct DisplayEnumerator {

    public init() {}

    /// Returns info for all currently online displays.
    public static func allDisplays() -> [DisplayInfo] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map { displayInfo(for: $0) }
    }

    /// Returns only non-built-in (external) displays.
    public func connectedExternalDisplays() throws -> [DisplayInfo] {
        DisplayEnumerator.allDisplays().filter { !$0.isBuiltIn }
    }

    // MARK: - Per-display resolution

    private static func displayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo {
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        let (nativeWidth, nativeHeight) = nativeResolution(for: displayID)

        if let ioInfo = ioKitInfo(for: displayID) {
            return DisplayInfo(
                vendorID: ioInfo.vendorID,
                productID: ioInfo.productID,
                displayID: displayID,
                name: ioInfo.name,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight,
                isBuiltIn: isBuiltIn,
                connectionType: ioInfo.connectionType
            )
        }

        // Fallback: use CGDisplay-derived values only
        let vendorID = UInt32(CGDisplayVendorNumber(displayID))
        let productID = UInt32(CGDisplayModelNumber(displayID))
        return DisplayInfo(
            vendorID: vendorID,
            productID: productID,
            displayID: displayID,
            name: "Display \(String(format: "%04x:%04x", vendorID, productID))",
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            isBuiltIn: isBuiltIn,
            connectionType: .unknown
        )
    }

    // MARK: - Native resolution detection

    /// IOKit native-timing flag (`kDisplayModeNativeFlag` from IOGraphicsTypes.h).
    /// Not surfaced in the CoreGraphics headers, so declared here. Empirically
    /// validated against connected hardware: filtering modes by this bit yields
    /// exactly the panel's physical timings.
    static let nativeModeFlag: UInt32 = 0x0200_0000

    /// Resolves the panel's true native pixel resolution for a display.
    ///
    /// `CGDisplayBounds` reports logical *points*, so on a HiDPI-active display
    /// it returns the scaled "looks like" size (e.g. 1920×1080 on a 2560×1440
    /// panel running a 2× mode) — not the panel's physical resolution. This
    /// enumerates the real display modes and selects the native one.
    private static func nativeResolution(for displayID: CGDirectDisplayID) -> (Int, Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
            let descriptors = modes.map {
                DisplayModeDescriptor(
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    pointWidth: $0.width,
                    ioFlags: $0.ioFlags
                )
            }
            if let native = selectNativeResolution(from: descriptors) {
                return native
            }
        }

        // Fallbacks: current mode's pixel size, then logical bounds (points).
        if let current = CGDisplayCopyDisplayMode(displayID) {
            return (current.pixelWidth, current.pixelHeight)
        }
        let bounds = CGDisplayBounds(displayID)
        return (Int(bounds.width), Int(bounds.height))
    }

    /// Pure selection logic, separated from CoreGraphics so it can be tested
    /// against captured hardware mode sets.
    ///
    /// Strategy:
    ///   1. Prefer the largest pixel resolution among native-flagged modes —
    ///      these are the panel's physical timings and exclude HiDPI
    ///      "more space" modes whose framebuffer is supersampled above native.
    ///   2. Fall back to the largest 1× mode (`pixelWidth == pointWidth`, i.e.
    ///      no supersampling) when no mode carries the native flag.
    static func selectNativeResolution(from modes: [DisplayModeDescriptor]) -> (width: Int, height: Int)? {
        let area: (DisplayModeDescriptor, DisplayModeDescriptor) -> Bool = {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }

        let nativeFlagged = modes.filter { $0.ioFlags & nativeModeFlag != 0 }
        if let best = nativeFlagged.max(by: area) {
            return (best.pixelWidth, best.pixelHeight)
        }

        let oneX = modes.filter { $0.pixelWidth == $0.pointWidth }
        if let best = oneX.max(by: area) {
            return (best.pixelWidth, best.pixelHeight)
        }

        return nil
    }

    // MARK: - IOKit lookup

    private struct IOKitDisplayInfo {
        let vendorID: UInt32
        let productID: UInt32
        let name: String
        let connectionType: ConnectionType
    }

    private static func ioKitInfo(for displayID: CGDirectDisplayID) -> IOKitDisplayInfo? {
        let vendorID = UInt32(CGDisplayVendorNumber(displayID))
        let productID = UInt32(CGDisplayModelNumber(displayID))

        let matching = IOServiceMatching("IODisplayConnect")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let entryVendor = info[kDisplayVendorID] as? UInt32 ?? 0
            let entryProduct = info[kDisplayProductID] as? UInt32 ?? 0

            guard entryVendor == vendorID, entryProduct == productID else {
                continue
            }

            let name = extractDisplayName(from: info) ?? "Display \(String(format: "%04x:%04x", vendorID, productID))"
            let connectionType = extractConnectionType(from: info, name: name)

            return IOKitDisplayInfo(
                vendorID: vendorID,
                productID: productID,
                name: name,
                connectionType: connectionType
            )
        }
        return nil
    }

    private static func extractDisplayName(from info: [String: Any]) -> String? {
        // DisplayProductName is a dict keyed by locale code, e.g. ["en_US": "DELL S2721DGF"]
        guard let nameDict = info[kDisplayProductName] as? [String: String] else {
            return nil
        }
        // Prefer English; fall back to first available locale
        return nameDict["en_US"] ?? nameDict.values.first
    }

    private static func extractConnectionType(from info: [String: Any], name: String) -> ConnectionType {
        // IOKit may expose a Transport key with a sub-dict containing a "Graphics Transport"
        if let transport = info["Transport"] as? [String: Any],
           let transportType = transport["Graphics Transport"] as? String {
            return connectionType(from: transportType)
        }

        // Fall back to name-based heuristics
        let lower = name.lowercased()
        if lower.contains("displayport") || lower.contains("dp") {
            return .displayPort
        } else if lower.contains("hdmi") {
            return .hdmi
        } else if lower.contains("thunderbolt") || lower.contains("tb") {
            return .displayPort
        } else if lower.contains("vga") {
            return .vga
        } else if lower.contains("dvi") {
            return .dvi
        } else if lower.contains("usb-c") || lower.contains("usbc") || lower.contains("type-c") {
            return .usbc
        }
        return .unknown
    }

    private static func connectionType(from transportString: String) -> ConnectionType {
        switch transportString.lowercased() {
        case let s where s.contains("displayport"): return .displayPort
        case let s where s.contains("hdmi"):        return .hdmi
        case let s where s.contains("thunderbolt"): return .displayPort
        case let s where s.contains("vga"):         return .vga
        case let s where s.contains("dvi"):         return .dvi
        case let s where s.contains("usb"):         return .usbc
        default:                                     return .unknown
        }
    }
}
