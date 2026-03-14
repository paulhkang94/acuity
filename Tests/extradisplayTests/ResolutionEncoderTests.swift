import XCTest
@testable import extradisplay

final class ResolutionEncoderTests: XCTestCase {

    // MARK: - 1280×720 HiDPI encoding

    func testEncoding1280x720_physicalDimensionsInFirstVariant() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        let variants = entry.allVariants()
        XCTAssertFalse(variants.isEmpty, "allVariants() must not be empty")

        let first = variants[0]
        // physW = 1280 * 2 = 2560 = 0x00000A00
        let physW = first.subdata(in: 0..<4)
        XCTAssertEqual(physW, Data([0x00, 0x00, 0x0A, 0x00]), "physW for 1280 must be 0x00000A00")

        // physH = 720 * 2 = 1440 = 0x000005A0
        let physH = first.subdata(in: 4..<8)
        XCTAssertEqual(physH, Data([0x00, 0x00, 0x05, 0xA0]), "physH for 720 must be 0x000005A0")
    }

    // MARK: - 1920×1080 HiDPI encoding

    func testEncoding1920x1080_physicalDimensionsInFirstVariant() {
        let entry = HiDPIEntry(logicalWidth: 1920, logicalHeight: 1080)
        let variants = entry.allVariants()

        let first = variants[0]
        // physW = 1920 * 2 = 3840 = 0x00000F00
        let physW = first.subdata(in: 0..<4)
        XCTAssertEqual(physW, Data([0x00, 0x00, 0x0F, 0x00]), "physW for 1920 must be 0x00000F00")

        // physH = 1080 * 2 = 2160 = 0x00000870
        let physH = first.subdata(in: 4..<8)
        XCTAssertEqual(physH, Data([0x00, 0x00, 0x08, 0x70]), "physH for 1080 must be 0x00000870")
    }

    // MARK: - Variant count

    func testAllVariantsReturnsExactlyThreeEntries() {
        let entry = HiDPIEntry(logicalWidth: 2560, logicalHeight: 1440)
        XCTAssertEqual(entry.allVariants().count, 3, "allVariants() must return exactly 3 entries")
    }

    // MARK: - Suffix bytes per variant

    func testVariant0_bareSuffix() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        let v0 = entry.allVariants()[0]
        // bare suffix: [0x00] — total size = 8 + 1 = 9 bytes
        XCTAssertEqual(v0.count, 9, "Bare variant must be 9 bytes total")
        XCTAssertEqual(v0[8], 0x00, "Bare variant suffix byte must be 0x00")
    }

    func testVariant1_hiDPISuffix() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        let v1 = entry.allVariants()[1]
        // HiDPI suffix: [0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00] — total = 16 bytes
        XCTAssertEqual(v1.count, 16, "HiDPI variant must be 16 bytes total")
        let expectedSuffix = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00])
        XCTAssertEqual(v1.subdata(in: 8..<16), expectedSuffix, "HiDPI variant suffix mismatch")
    }

    func testVariant2_extendedSuffix() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        let v2 = entry.allVariants()[2]
        // Extended suffix: [0x00, 0x00, 0x00, 0x01, 0x0A, 0x0A, 0x00, 0x00] — total = 16 bytes
        XCTAssertEqual(v2.count, 16, "Extended variant must be 16 bytes total")
        let expectedSuffix = Data([0x00, 0x00, 0x00, 0x01, 0x0A, 0x0A, 0x00, 0x00])
        XCTAssertEqual(v2.subdata(in: 8..<16), expectedSuffix, "Extended variant suffix mismatch")
    }

    // MARK: - Base64 encoding

    func testBase64EncodingOfFirstVariant_1280x720() {
        let entry = HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)
        let variants = entry.allVariants()

        // bare variant: [0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x05, 0xA0, 0x00]
        let expectedData = Data([0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x05, 0xA0, 0x00])
        let expectedBase64 = expectedData.base64EncodedString()

        XCTAssertEqual(
            variants[0].base64EncodedString(),
            expectedBase64,
            "Base64 of first variant for 1280×720 must match expected encoding"
        )
    }
}
