import CoreGraphics
import Foundation

/// Public facade for DDC/CI monitor control.
///
/// Validates all values against the MCCS-defined ranges before transmitting.
/// Throws `DDCError` on range violations or communication failures.
public struct DDCController {

    // MARK: Brightness

    /// Sets monitor brightness. Value must be in 0–100.
    public static func setBrightness(_ value: Int, display: DisplayInfo) throws {
        try validateRange(value, for: .brightness)
        let bridge = try IOAVServiceBridge(displayID: display.displayID)
        try bridge.writeDDC(displayID: display.displayID, vcpCode: .brightness, value: value)
    }

    /// Returns the current brightness value (0–100).
    public static func getBrightness(display: DisplayInfo) throws -> Int {
        let bridge = try IOAVServiceBridge(displayID: display.displayID)
        let result = try bridge.readDDC(displayID: display.displayID, vcpCode: .brightness)
        return result.current
    }

    // MARK: Contrast

    /// Sets monitor contrast. Value must be in 0–100.
    public static func setContrast(_ value: Int, display: DisplayInfo) throws {
        try validateRange(value, for: .contrast)
        let bridge = try IOAVServiceBridge(displayID: display.displayID)
        try bridge.writeDDC(displayID: display.displayID, vcpCode: .contrast, value: value)
    }

    // MARK: Input Source

    /// Switches the active input source.
    public static func setInput(_ source: InputSource, display: DisplayInfo) throws {
        let bridge = try IOAVServiceBridge(displayID: display.displayID)
        try bridge.writeDDC(displayID: display.displayID, vcpCode: .inputSource, value: Int(source.rawValue))
    }

    // MARK: - Validation

    private static func validateRange(_ value: Int, for code: VCPCode) throws {
        guard code.validRange.contains(value) else {
            throw DDCError.valueOutOfRange(code, value, code.validRange)
        }
    }
}
