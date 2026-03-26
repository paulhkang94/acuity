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

// IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service) -> IOAVServiceRef
// BUG FIX: previously declared as (CFAllocator?) -> ... missing the io_service_t second parameter.
// On ARM64 x1 held garbage, so createFn always returned nil → every DDC op threw serviceNotFound.
private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?

private typealias IOAVServiceReadI2CFn = @convention(c) (
    CFTypeRef,               // service
    UInt32,                  // chipAddress
    UInt32,                  // offset
    UnsafeMutableRawPointer, // outputBuffer
    UInt32                   // outputBufferSize
) -> Int32

private typealias IOAVServiceWriteI2CFn = @convention(c) (
    CFTypeRef,               // service
    UInt32,                  // chipAddress
    UInt32,                  // dataAddress
    UnsafeMutableRawPointer, // inputBuffer
    UInt32                   // inputBufferSize
) -> Int32

// MARK: - DDC command constants

private let kDDCGetVCPFeatureRequest: UInt8 = 0x01
private let kDDCGetVCPFeatureReply: UInt8   = 0x02
private let kDDCSetVCPFeatureRequest: UInt8 = 0x03
private let kDDCHostAddress: UInt8          = 0x51
private let kDDCMonitorAddress: UInt8       = 0x6E

// MARK: - IOAVServiceBridge

/// Provides DDC/CI read and write access to external monitors via the private IOAVService framework.
/// Uses dlsym-based dynamic loading to avoid requiring a private entitlement at build time.
///
/// Supported: Apple Silicon Macs with monitors connected via DisplayPort, HDMI, or USB-C.
/// Not supported: Intel Macs, or displays without DDC/CI.
final class IOAVServiceBridge {

    // MARK: Loaded symbols

    private let serviceHandle: CFTypeRef
    private let readI2C: IOAVServiceReadI2CFn
    private let writeI2C: IOAVServiceWriteI2CFn

    // MARK: Init

    // macOS 12–15: IOAVService.framework
    // macOS 26+:   symbols moved to DisplayTransportServices.framework (and re-exported by
    //              several others). Try each path in order; first successful load wins.
    private static let candidateLibPaths: [String] = [
        "/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService",
        "/System/Library/PrivateFrameworks/DisplayTransportServices.framework/DisplayTransportServices",
        "/System/Library/PrivateFrameworks/DSExternalDisplay.framework/DSExternalDisplay",
        "/System/Library/PrivateFrameworks/HIDDisplay.framework/HIDDisplay",
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    ]

    init(displayID: CGDirectDisplayID) throws {
        print("PHK IOAVServiceBridge.init: displayID=\(displayID)")

        // Try framework paths in order — macOS 26 removed IOAVService.framework and
        // re-exports the same symbols from DisplayTransportServices.framework.
        var libHandle: UnsafeMutableRawPointer? = nil
        var loadedPath = "<none>"
        for path in IOAVServiceBridge.candidateLibPaths {
            libHandle = dlopen(path, RTLD_NOW)
            if libHandle != nil { loadedPath = path; break }
        }
        guard let libHandle else {
            let reason = String(cString: dlerror())
            print("PHK IOAVServiceBridge.init: all dlopen paths FAILED — \(reason)")
            throw DDCError.serviceUnavailable("dlopen failed on all candidate paths: \(reason)")
        }
        print("PHK IOAVServiceBridge.init: dlopen OK via \(loadedPath)")

        guard
            let createSym = dlsym(libHandle, "IOAVServiceCreateWithService"),
            let readSym   = dlsym(libHandle, "IOAVServiceReadI2C"),
            let writeSym  = dlsym(libHandle, "IOAVServiceWriteI2C")
        else {
            dlclose(libHandle)
            print("PHK IOAVServiceBridge.init: required symbols NOT found")
            throw DDCError.serviceUnavailable("Required symbols not found in IOAVService.framework")
        }
        print("PHK IOAVServiceBridge.init: symbols resolved OK")

        let createFn = unsafeBitCast(createSym, to: IOAVServiceCreateFn.self)
        self.readI2C  = unsafeBitCast(readSym,  to: IOAVServiceReadI2CFn.self)
        self.writeI2C = unsafeBitCast(writeSym, to: IOAVServiceWriteI2CFn.self)

        guard let service = IOAVServiceBridge.findService(for: displayID, createFn: createFn) else {
            dlclose(libHandle)
            print("PHK IOAVServiceBridge.init: findService returned nil for displayID=\(displayID)")
            throw DDCError.serviceNotFound(displayID)
        }
        print("PHK IOAVServiceBridge.init: service found ✓")
        self.serviceHandle = service
    }

    // MARK: Public API

    func readDDC(displayID: CGDirectDisplayID, vcpCode: VCPCode) throws -> (current: Int, max: Int) {
        print("PHK readDDC: displayID=\(displayID) vcp=0x\(String(format: "%02X", vcpCode.rawValue))")

        var request: [UInt8] = [
            kDDCHostAddress,
            0x03,
            kDDCGetVCPFeatureRequest,
            vcpCode.rawValue,
            0x00,
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
        print("PHK readDDC: write request status=\(writeStatus)")
        guard writeStatus == 0 else { throw DDCError.writeFailed(vcpCode, writeStatus) }

        usleep(50_000)

        var replyBuffer = [UInt8](repeating: 0, count: 12)
        let readStatus = readI2C(
            serviceHandle,
            UInt32(kDDCMonitorAddress),
            UInt32(kDDCHostAddress),
            &replyBuffer,
            UInt32(replyBuffer.count)
        )
        print("PHK readDDC: read status=\(readStatus) reply=\(replyBuffer.map { String(format: "%02X", $0) }.joined(separator: " "))")
        guard readStatus == 0 else { throw DDCError.readFailed(vcpCode, readStatus) }

        guard replyBuffer.count >= 10,
              replyBuffer[2] == kDDCGetVCPFeatureReply,
              replyBuffer[4] == vcpCode.rawValue
        else {
            print("PHK readDDC: invalid response structure")
            throw DDCError.invalidResponse
        }

        let maxValue = Int(replyBuffer[6]) << 8 | Int(replyBuffer[7])
        let curValue = Int(replyBuffer[8]) << 8 | Int(replyBuffer[9])
        print("PHK readDDC: current=\(curValue) max=\(maxValue)")
        return (current: curValue, max: maxValue)
    }

    func writeDDC(displayID: CGDirectDisplayID, vcpCode: VCPCode, value: Int) throws {
        print("PHK writeDDC: displayID=\(displayID) vcp=0x\(String(format: "%02X", vcpCode.rawValue)) value=\(value)")

        let valueMSB = UInt8((value >> 8) & 0xFF)
        let valueLSB = UInt8(value & 0xFF)

        var request: [UInt8] = [
            kDDCHostAddress,
            0x04,
            kDDCSetVCPFeatureRequest,
            vcpCode.rawValue,
            valueMSB,
            valueLSB,
            0x00,
        ]
        request[6] = ddcChecksum(Array(request[1...5]), destinationAddress: kDDCMonitorAddress)
        print("PHK writeDDC: bytes=\(request.map { String(format: "%02X", $0) }.joined(separator: " "))")

        var requestBuffer = request
        let status = writeI2C(
            serviceHandle,
            UInt32(kDDCMonitorAddress),
            UInt32(kDDCHostAddress),
            &requestBuffer,
            UInt32(requestBuffer.count)
        )
        print("PHK writeDDC: writeI2C status=\(status) \(status == 0 ? "✓" : "FAILED")")
        guard status == 0 else { throw DDCError.writeFailed(vcpCode, status) }
    }

    // MARK: - Availability

    static func isAvailable() -> Bool {
        for path in candidateLibPaths {
            if let h = dlopen(path, RTLD_NOW) { dlclose(h); return true }
        }
        return false
    }

    // MARK: - Service lookup

    /// Walks IOAVService entries and returns the one matching this display.
    ///
    /// Matching strategy:
    ///   1. Match by IODisplayUnit == CGDisplayUnitNumber (most reliable when metadata present)
    ///   2. Fall back to the first service if only one entry exists or unitNumber == 0
    private static func findService(
        for displayID: CGDirectDisplayID,
        createFn: IOAVServiceCreateFn
    ) -> CFTypeRef? {
        let matching = IOServiceMatching("IOAVService")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            print("PHK findService: IOServiceGetMatchingServices FAILED")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let unitNumber = CGDisplayUnitNumber(displayID)
        print("PHK findService: looking for displayID=\(displayID) unitNumber=\(unitNumber)")

        var matchedService: CFTypeRef?
        var firstService: CFTypeRef?
        var totalEntries = 0

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            var entryUnit: UInt32 = 0
            if let prop = IORegistryEntryCreateCFProperty(
                entry, "IODisplayUnit" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() {
                entryUnit = (prop as? UInt32) ?? 0
            }

            // Also grab the service location string for logging
            var locationBuf = [CChar](repeating: 0, count: 256)
            let locationStr: String
            if IORegistryEntryGetLocationInPlane(entry, kIOServicePlane, &locationBuf) == KERN_SUCCESS {
                locationStr = String(cString: locationBuf)
            } else {
                locationStr = "<no location>"
            }
            print("PHK findService: entry[\(totalEntries)] io_service=\(entry) IODisplayUnit=\(entryUnit) location=\(locationStr)")

            // Pass the actual io_service_t entry — this was the bug: previously called with no
            // second argument, so x1 was garbage and IOAVServiceCreateWithService returned nil.
            if let svc = createFn(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                if firstService == nil {
                    firstService = svc
                }
                if entryUnit == unitNumber {
                    print("PHK findService: unit match at entry[\(totalEntries)] ✓")
                    matchedService = svc
                }
            } else {
                print("PHK findService: createFn returned nil for entry[\(totalEntries)]")
            }

            totalEntries += 1
        }

        print("PHK findService: scanned \(totalEntries) IOAVService entries; matched=\(matchedService != nil) firstAvail=\(firstService != nil)")

        if let matched = matchedService { return matched }

        // Fallback: single-display setups or missing IODisplayUnit metadata
        if totalEntries == 1 || unitNumber == 0 {
            print("PHK findService: using fallback firstService")
            return firstService
        }

        return nil
    }

    // MARK: - Helpers

    private func ddcChecksum(_ bytes: [UInt8], destinationAddress: UInt8) -> UInt8 {
        var checksum = destinationAddress << 1
        for byte in bytes { checksum ^= byte }
        return checksum
    }
}
