import CoreGraphics
import Foundation

/// The physical connection type reported for a display.
public enum ConnectionType: String, CaseIterable, CustomStringConvertible {
    case displayPort = "DisplayPort"
    case hdmi        = "HDMI"
    case usbc        = "USB-C"
    case dvi         = "DVI"
    case vga         = "VGA"
    case unknown     = "Unknown"

    public var description: String { rawValue }
}

/// Identifies a connected display and carries the metadata needed to generate
/// and apply HiDPI overrides.
public struct DisplayInfo {

    // MARK: - Properties

    /// EDID vendor identifier.
    public let vendorID: UInt32

    /// EDID product identifier.
    public let productID: UInt32

    /// CoreGraphics display identifier for the current session.
    public let displayID: CGDirectDisplayID

    /// Human-readable name sourced from IOKit or a fallback.
    public let name: String

    /// Native (physical) horizontal resolution in pixels.
    public let nativeWidth: Int

    /// Native (physical) vertical resolution in pixels.
    public let nativeHeight: Int

    /// `true` for the built-in display on notebooks.
    public let isBuiltIn: Bool

    /// Physical connection type.
    public let connectionType: ConnectionType

    // MARK: - Initializer

    public init(
        vendorID: UInt32,
        productID: UInt32,
        displayID: CGDirectDisplayID,
        name: String,
        nativeWidth: Int,
        nativeHeight: Int,
        isBuiltIn: Bool,
        connectionType: ConnectionType
    ) {
        self.vendorID       = vendorID
        self.productID      = productID
        self.displayID      = displayID
        self.name           = name
        self.nativeWidth    = nativeWidth
        self.nativeHeight   = nativeHeight
        self.isBuiltIn      = isBuiltIn
        self.connectionType = connectionType
    }

    // MARK: - Computed properties

    /// Filesystem identifier used by the macOS Overrides directory convention.
    ///
    /// Example: `DisplayVendorID-610:DisplayProductID-a034`
    public var overrideIdentifier: String {
        let v = String(vendorID, radix: 16, uppercase: false)
        let p = String(productID, radix: 16, uppercase: false)
        return "DisplayVendorID-\(v):DisplayProductID-\(p)"
    }

    /// `true` for any display that is not the built-in panel.
    public var isExternal: Bool { !isBuiltIn }
}

// MARK: - CustomStringConvertible

extension DisplayInfo: CustomStringConvertible {
    public var description: String {
        "\(name) [\(nativeWidth)×\(nativeHeight)] via \(connectionType)"
    }
}
