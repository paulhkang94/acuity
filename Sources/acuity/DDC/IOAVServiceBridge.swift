import CoreGraphics
import Foundation
import IOKit

// Dynamic bridge to IOAVService.framework (private, no static entitlement needed when using dlsym)

// MARK: - Errors

public enum DDCError: LocalizedError {
    case serviceUnavailable(String)
    case serviceNotFound(CGDirectDisplayID)
    case readFailed(VCPCode, Int32)
    case writeFailed(VCPCode, Int32)
    case invalidResponse
    case valueOutOfRange(VCPCode, Int, ClosedRange<Int>)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let reason):
            return "IOAVService is unavailable: \(reason). DDC/CI requires Apple Silicon with a compatible display connection."
        case .serviceNotFound(let displayID):
            return "No IOAVService found for display \(displayID). The display may not support DDC/CI over this connection."
        case .readFailed(let code, let status):
            return "DDC read failed for \(code.description) (VCP 0x\(String(format: "%02X", code.rawValue))): IOReturn 0x\(String(format: "%08X", status))"
        case .writeFailed(let code, let status):
            return "DDC write failed for \(code.description) (VCP 0x\(String(format: "%02X", code.rawValue))): IOReturn 0x\(String(format: "%08X", status))"
        case .invalidResponse:
            return "DDC response was malformed or empty."
        case .valueOutOfRange(let code, let value, let range):
            return "Value \(value) is outside valid range \(range.lowerBound)–\(range.upperBound) for \(code.description)."
        }
    }
}

// MARK: - Function-pointer typedefs matching IOAVService SPI

private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
private typealias IOAVServiceReadI2CFn = @convention(c) (
    CFTypeRef,          // service
    UInt32,             // chipAddress
    UInt32,             // offset
    UnsafeMutableRawPointer, // outputBuffer
    UInt32              // outputBufferSize
) -> Int32

private typealias IOAVServiceWriteI2CFn = @convention(c) (
    CFTypeRef,          // service
    UInt32,             // chipAddress
    UInt32,             // dataAddress
    UnsafeMutableRawPointer, // inputBuffer
    UInt32              // inputBufferSize
) -> Int32

// MARK: - DDC command constants

private let kDDCAddress: UInt32 = 0x37
private let kDDCGetVCPFeatureRequest: UInt8 = 0x01
private let kDDCGetVCPFeatureReply: UInt8 = 0x02
private let kDDCSetVCPFeatureRequest: UInt8 = 0x03
private let kDDCI2CSlaveAddress: UInt32 = 0x37
private let kDDCHostAddress: UInt8 = 0x51
private let kDDCMonitorAddress: UInt8 = 0x6E

// MARK: - IOAVServiceBridge

/// Provides DDC/CI read and write access to external monitors via the private IOAVService framework.
/// Uses dlsym-based dynamic loading to avoid requiring a private entitlement at build time.
///
/// Supported: Apple Silicon Macs with monitors connected via DisplayPort, HDMI, or USB-C.
/// Not supported: Intel Macs (use DDCKit or arm64-only alternative), or displays without DDC/CI.
final class IOAVServiceBridge {

    // MARK: Loaded symbols

    private let serviceHandle: CFTypeRef
    private let readI2C: IOAVServiceReadI2CFn
    private let writeI2C: IOAVServiceWriteI2CFn

    // MARK: Init

    /// Initialises the bridge for a specific display, or throws `DDCError` if unavailable.
    init(displayID: CGDirectDisplayID) throws {
        let handle = dlopen("/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService", RTLD_NOW)
        guard let handle else {
            let reason = String(cString: dlerror())
            throw DDCError.serviceUnavailable("dlopen failed: \(reason)")
        }

        guard
            let createSym   = dlsym(handle, "IOAVServiceCreateWithService"),
            let readSym     = dlsym(handle, "IOAVServiceReadI2C"),
            let writeSym    = dlsym(handle, "IOAVServiceWriteI2C")
        else {
            dlclose(handle)
            throw DDCError.serviceUnavailable("Required symbols not found in IOAVService.framework")
        }

        let createFn = unsafeBitCast(createSym, to: IOAVServiceCreateFn.self)
        self.readI2C  = unsafeBitCast(readSym,  to: IOAVServiceReadI2CFn.self)
        self.writeI2C = unsafeBitCast(writeSym, to: IOAVServiceWriteI2CFn.self)

        // Locate the IOAVService instance matching this CGDirectDisplayID
        guard let service = IOAVServiceBridge.findService(for: displayID, createFn: createFn) else {
            dlclose(handle)
            throw DDCError.serviceNotFound(displayID)
        }
        self.serviceHandle = service
    }

    // MARK: Public API

    /// Reads the current and maximum value for a VCP feature code.
    func readDDC(displayID: CGDirectDisplayID, vcpCode: VCPCode) throws -> (current: Int, max: Int) {
        // Build the DDC Get VCP Feature request (7 bytes)
        var request: [UInt8] = [
            kDDCHostAddress,                // source address (host)
            0x03,                           // message length
            kDDCGetVCPFeatureRequest,       // command: get VCP feature
            vcpCode.rawValue,               // VCP opcode
            0x00,                           // placeholder for checksum
        ]
        request[4] = ddcChecksum(Array(request[1...]), destinationAddress: kDDCMonitorAddress)

        var requestBuffer = request
        let writeStatus = writeI2C(
            serviceHandle,
            UInt32(kDDCMonitorAddress),
            UInt32(kDDCHostAddress),
            &requestBuffer,
            UInt32(requestBuffer.count)
        )
        guard writeStatus == 0 else {
            throw DDCError.writeFailed(vcpCode, writeStatus)
        }

        // Allow monitor time to prepare the reply (~50 ms is standard per MCCS spec)
        usleep(50_000)

        // Read the reply (12 bytes: DDC Get VCP Feature Reply)
        var replyBuffer = [UInt8](repeating: 0, count: 12)
        let readStatus = readI2C(
            serviceHandle,
            UInt32(kDDCMonitorAddress),
            UInt32(kDDCHostAddress),
            &replyBuffer,
            UInt32(replyBuffer.count)
        )
        guard readStatus == 0 else {
            throw DDCError.readFailed(vcpCode, readStatus)
        }

        // Validate reply structure:
        // byte 0: destination (0x51), byte 2: opcode (0x02), byte 4: VCP code echo
        guard replyBuffer.count >= 8,
              replyBuffer[2] == kDDCGetVCPFeatureReply,
              replyBuffer[4] == vcpCode.rawValue else {
            throw DDCError.invalidResponse
        }

        let maxValue = Int(replyBuffer[6]) << 8 | Int(replyBuffer[7])
        let curValue = Int(replyBuffer[8]) << 8 | Int(replyBuffer[9])
        return (current: curValue, max: maxValue)
    }

    /// Writes a value for a VCP feature code.
    func writeDDC(displayID: CGDirectDisplayID, vcpCode: VCPCode, value: Int) throws {
        let valueMSB = UInt8((value >> 8) & 0xFF)
        let valueLSB = UInt8(value & 0xFF)

        var request: [UInt8] = [
            kDDCHostAddress,            // source address
            0x04,                       // message length
            kDDCSetVCPFeatureRequest,   // command: set VCP feature
            vcpCode.rawValue,           // VCP opcode
            valueMSB,
            valueLSB,
            0x00,                       // placeholder for checksum
        ]
        request[6] = ddcChecksum(Array(request[1...5]), destinationAddress: kDDCMonitorAddress)

        var requestBuffer = request
        let status = writeI2C(
            serviceHandle,
            UInt32(kDDCMonitorAddress),
            UInt32(kDDCHostAddress),
            &requestBuffer,
            UInt32(requestBuffer.count)
        )
        guard status == 0 else {
            throw DDCError.writeFailed(vcpCode, status)
        }
    }

    // MARK: - Availability check

    /// Returns true if IOAVService is loadable on this system (Apple Silicon required).
    static func isAvailable() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService", RTLD_NOW
        ) else { return false }
        dlclose(handle)
        return true
    }

    // MARK: - Internals

    /// Walks the IOService plane to find the IOAVService for the given display.
    private static func findService(
        for displayID: CGDirectDisplayID,
        createFn: IOAVServiceCreateFn
    ) -> CFTypeRef? {
        let matching = IOServiceMatching("IOAVService")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        // On single-display setups the first service is typically the right one.
        // On multi-display setups we match by display unit number embedded in the service path.
        let unitNumber = CGDisplayUnitNumber(displayID)

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            // Read the "IODisplayUnit" property to match against the CGDisplay unit
            var entryUnit: UInt32 = 0
            let propKey = "IODisplayUnit" as CFString
            if let prop = IORegistryEntryCreateCFProperty(entry, propKey, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                entryUnit = (prop as? UInt32) ?? 0
            }

            if entryUnit == unitNumber || unitNumber == 0 {
                if let svc = createFn(kCFAllocatorDefault)?.takeRetainedValue() {
                    return svc
                }
            }
        }
        return nil
    }

    /// Computes the XOR checksum used in DDC/CI messages.
    private func ddcChecksum(_ bytes: [UInt8], destinationAddress: UInt8) -> UInt8 {
        var checksum = destinationAddress << 1
        for byte in bytes {
            checksum ^= byte
        }
        return checksum
    }
}
