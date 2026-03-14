import XCTest
@testable import extradisplay

/// Tests for HiDPIEntry binary encoding.
///
/// Ground truth: Apple's own scale-resolutions entries from
/// /System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-9ccd
/// Every Apple entry is exactly 12 bytes:
///   [4B physW big-endian] [4B physH big-endian] [0x00 0x00 0x00 0x01]
/// where physW = logicalWidth × 2, physH = logicalHeight × 2.
final class ResolutionEncoderTests: XCTestCase {

    // MARK: - Apple canonical format: 12 bytes, 1 entry

    func test_allVariants_returnsExactlyOneEntry() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        XCTAssertEqual(entry.allVariants().count, 1,
            "allVariants() must return exactly 1 entry (Apple canonical format)")
    }

    func test_entry_is12Bytes() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        XCTAssertEqual(entry.allVariants()[0].count, 12,
            "Each scale-resolutions entry must be exactly 12 bytes (Apple canonical)")
    }

    // MARK: - Physical dimension encoding (bytes 0–7)

    func test_1280x720_physicalWidth_is2560() {
        let data = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720).allVariants()[0]
        XCTAssertEqual(data.subdata(in: 0..<4), Data([0x00, 0x00, 0x0A, 0x00]),
            "physW for logical 1280 must be 0x00000A00 (2560 big-endian)")
    }

    func test_1280x720_physicalHeight_is1440() {
        let data = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720).allVariants()[0]
        XCTAssertEqual(data.subdata(in: 4..<8), Data([0x00, 0x00, 0x05, 0xA0]),
            "physH for logical 720 must be 0x000005A0 (1440 big-endian)")
    }

    func test_1920x1080_physicalWidth_is3840() {
        let data = HiDPIEntry(logicalWidth: 1920, logicalHeight: 1080).allVariants()[0]
        XCTAssertEqual(data.subdata(in: 0..<4), Data([0x00, 0x00, 0x0F, 0x00]),
            "physW for logical 1920 must be 0x00000F00 (3840 big-endian)")
    }

    func test_1920x1080_physicalHeight_is2160() {
        let data = HiDPIEntry(logicalWidth: 1920, logicalHeight: 1080).allVariants()[0]
        XCTAssertEqual(data.subdata(in: 4..<8), Data([0x00, 0x00, 0x08, 0x70]),
            "physH for logical 1080 must be 0x00000870 (2160 big-endian)")
    }

    // MARK: - HiDPI flag (bytes 8–11)

    func test_flagBytes_are_0x00000001_forAllResolutions() {
        for (w, h) in [(1280, 720), (1920, 1080), (2560, 1440), (1440, 810)] {
            let data = HiDPIEntry(logicalWidth: w, logicalHeight: h).allVariants()[0]
            XCTAssertEqual(data.subdata(in: 8..<12), Data([0x00, 0x00, 0x00, 0x01]),
                "Flag bytes for \(w)×\(h) must be 0x00000001 (Apple HiDPI mode flag)")
        }
    }

    // MARK: - Full byte sequence: cross-check against Apple canonical base64 strings
    //
    // These expected values are derived from the same arithmetic Apple uses in
    // /System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/.
    // If any of these fail, our encoding diverges from Apple's format and the
    // plist will not produce HiDPI modes after reboot.

    func test_1280x720_fullByteSequence_matchesAppleFormat() {
        // physW=2560=0x00000A00, physH=1440=0x000005A0, flag=0x00000001
        let expected = Data([0x00,0x00,0x0A,0x00, 0x00,0x00,0x05,0xA0, 0x00,0x00,0x00,0x01])
        let actual   = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720).allVariants()[0]
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.base64EncodedString(), "AAAKAAAABaAAAAAB")
    }

    func test_1920x1080_fullByteSequence_matchesAppleFormat() {
        // physW=3840=0x00000F00, physH=2160=0x00000870, flag=0x00000001
        let expected = Data([0x00,0x00,0x0F,0x00, 0x00,0x00,0x08,0x70, 0x00,0x00,0x00,0x01])
        let actual   = HiDPIEntry(logicalWidth: 1920, logicalHeight: 1080).allVariants()[0]
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.base64EncodedString(), "AAAPAAAACHAAAAAB")
    }

    func test_2560x1440_fullByteSequence_matchesAppleFormat() {
        // physW=5120=0x00001400, physH=2880=0x00000B40, flag=0x00000001
        let expected = Data([0x00,0x00,0x14,0x00, 0x00,0x00,0x0B,0x40, 0x00,0x00,0x00,0x01])
        let actual   = HiDPIEntry(logicalWidth: 2560, logicalHeight: 1440).allVariants()[0]
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.base64EncodedString(), "AAAUAAAAC0AAAAAB")
    }
}
