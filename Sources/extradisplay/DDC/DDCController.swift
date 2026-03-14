import CoreGraphics
import Foundation

// MARK: - DDCControlling protocol

/// Dependency-injection protocol for DDC monitor control.
/// Use `DDCController` in production; inject `MockDDCController` in tests.
public protocol DDCControlling {
    func setBrightness(_ value: Int, display: DisplayInfo) throws
    func getBrightness(display: DisplayInfo) throws -> Int
    func setContrast(_ value: Int, display: DisplayInfo) throws
    func setInput(_ source: InputSource, display: DisplayInfo) throws
}

// MARK: - MockDDCController

/// Test double for DDCControlling. Records calls and returns configurable values.
public final class MockDDCController: DDCControlling {
    public var brightnessToReturn: Int = 50
    public var brightnessSetCalls: [(Int, DisplayInfo)] = []
    public var contrastSetCalls: [(Int, DisplayInfo)] = []
    public var inputSetCalls: [(InputSource, DisplayInfo)] = []
    public var shouldThrow: Error?

    public init() {}

    public func setBrightness(_ value: Int, display: DisplayInfo) throws {
        if let error = shouldThrow { throw error }
        brightnessSetCalls.append((value, display))
    }

    public func getBrightness(display: DisplayInfo) throws -> Int {
        if let error = shouldThrow { throw error }
        return brightnessToReturn
    }

    public func setContrast(_ value: Int, display: DisplayInfo) throws {
        if let error = shouldThrow { throw error }
        contrastSetCalls.append((value, display))
    }

    public func setInput(_ source: InputSource, display: DisplayInfo) throws {
        if let error = shouldThrow { throw error }
        inputSetCalls.append((source, display))
    }
}

// MARK: - DDCController

/// Public facade for DDC/CI monitor control.
///
/// Validates all values against the MCCS-defined ranges before transmitting.
/// Throws `DDCError` on range violations or communication failures.
public struct DDCController: DDCControlling {

    public init() {}

    // MARK: Brightness (instance)

    /// Sets monitor brightness. Value must be in 0–100.
    public func setBrightness(_ value: Int, display: DisplayInfo) throws {
        try DDCController.setBrightness(value, display: display)
    }

    /// Returns the current brightness value (0–100).
    public func getBrightness(display: DisplayInfo) throws -> Int {
        try DDCController.getBrightness(display: display)
    }

    // MARK: Contrast (instance)

    /// Sets monitor contrast. Value must be in 0–100.
    public func setContrast(_ value: Int, display: DisplayInfo) throws {
        try DDCController.setContrast(value, display: display)
    }

    // MARK: Input Source (instance)

    /// Switches the active input source.
    public func setInput(_ source: InputSource, display: DisplayInfo) throws {
        try DDCController.setInput(source, display: display)
    }

    // MARK: Brightness (static — kept for backward compat with existing commands)

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

    // MARK: Contrast (static)

    /// Sets monitor contrast. Value must be in 0–100.
    public static func setContrast(_ value: Int, display: DisplayInfo) throws {
        try validateRange(value, for: .contrast)
        let bridge = try IOAVServiceBridge(displayID: display.displayID)
        try bridge.writeDDC(displayID: display.displayID, vcpCode: .contrast, value: value)
    }

    // MARK: Input Source (static)

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
