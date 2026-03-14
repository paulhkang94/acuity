import Foundation

/// Encodes a logical HiDPI resolution into the binary format expected by
/// macOS `scale-resolutions` plist entries.
///
/// Binary format per entry:
///   [4 bytes: width*2 as big-endian UInt32]
///   [4 bytes: height*2 as big-endian UInt32]
///   [suffix bytes — variant-dependent]
///
/// Three suffix variants:
///   bare:     [0x00]
///   HiDPI:    [0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00]
///   extended: [0x00, 0x00, 0x00, 0x01, 0x0A, 0x0A, 0x00, 0x00]
public struct HiDPIEntry {
    public let logicalWidth: Int
    public let logicalHeight: Int

    public init(logicalWidth: Int, logicalHeight: Int) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }

    // MARK: - Binary encoding

    /// Returns the 3 binary variants for this logical resolution.
    public func allVariants() -> [Data] {
        let physW = UInt32(logicalWidth * 2)
        let physH = UInt32(logicalHeight * 2)

        var header = Data(capacity: 8)
        header.append(bigEndianBytes(physW))
        header.append(bigEndianBytes(physH))

        let suffixBare:     [UInt8] = [0x00]
        let suffixHiDPI:    [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00]
        let suffixExtended: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x0A, 0x0A, 0x00, 0x00]

        return [suffixBare, suffixHiDPI, suffixExtended].map { suffix in
            var data = header
            data.append(contentsOf: suffix)
            return data
        }
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
