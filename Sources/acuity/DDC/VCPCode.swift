import Foundation

// MARK: - VCPCode

/// Monitor Control Command Set (MCCS) Virtual Control Panel codes.
public enum VCPCode: UInt8, CaseIterable {
    case colorTemperature = 0x0C
    case brightness       = 0x10
    case contrast         = 0x12
    case inputSource      = 0x60
    case powerMode        = 0xD6

    public var description: String {
        switch self {
        case .colorTemperature: return "Color Temperature"
        case .brightness:       return "Brightness"
        case .contrast:         return "Contrast"
        case .inputSource:      return "Input Source"
        case .powerMode:        return "Power Mode"
        }
    }

    /// Valid value range for this control per the MCCS specification.
    public var validRange: ClosedRange<Int> {
        switch self {
        case .colorTemperature: return 0...100
        case .brightness:       return 0...100
        case .contrast:         return 0...100
        case .inputSource:      return 1...27
        case .powerMode:        return 1...5
        }
    }
}

// MARK: - InputSource

/// Standard MCCS input source identifiers (VCP 0x60).
public enum InputSource: UInt8 {
    case vga1          = 1
    case displayPort1  = 15
    case displayPort2  = 16
    case hdmi1         = 17
    case hdmi2         = 18
    case usbC          = 27

    public var description: String {
        switch self {
        case .vga1:         return "VGA 1"
        case .displayPort1: return "DisplayPort 1"
        case .displayPort2: return "DisplayPort 2"
        case .hdmi1:        return "HDMI 1"
        case .hdmi2:        return "HDMI 2"
        case .usbC:         return "USB-C"
        }
    }
}
