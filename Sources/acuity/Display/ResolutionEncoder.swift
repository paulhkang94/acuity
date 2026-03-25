import Foundation

/// Encodes a logical HiDPI resolution into the binary format expected by
/// macOS `scale-resolutions` plist entries.
///
/// Binary format per entry — Apple canonical (verified against
/// /System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/):
///
///   [4 bytes: width*2 as big-endian UInt32]   ← physical framebuffer width
///   [4 bytes: height*2 as big-endian UInt32]  ← physical framebuffer height
///   [4 bytes: 0x00000001]                     ← HiDPI mode flag
///
/// Total: 12 bytes per entry. WindowServer reads these at startup from
/// /Library/Displays/Contents/Resources/Overrides/ to populate available
/// scaled display modes.
public struct HiDPIEntry {
    public let logicalWidth: Int
    public let logicalHeight: Int

    public init(logicalWidth: Int, logicalHeight: Int) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }

    // MARK: - Binary encoding

    /// Returns one 12-byte entry in Apple's canonical scale-resolutions format.
    /// Physical dimensions = logical × 2 (2× HiDPI supersampling).
    public func allVariants() -> [Data] {
        let physW = UInt32(logicalWidth * 2)
        let physH = UInt32(logicalHeight * 2)

        var entry = Data(capacity: 12)
        entry.append(bigEndianBytes(physW))
        entry.append(bigEndianBytes(physH))
        entry.append(bigEndianBytes(UInt32(1)))  // 0x00000001 — HiDPI flag

        return [entry]
    }

    /// Returns Base64-encoded strings of each variant — useful for debugging.
    public func toBase64Strings() -> [String] {
        allVariants().map { $0.base64EncodedString() }
    }

    // MARK: - Helpers

    private func bigEndianBytes(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }
}
