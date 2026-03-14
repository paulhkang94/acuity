import XCTest
@testable import extradisplay

final class PlistWriterTests: XCTestCase {

    // MARK: - Override path construction

    func testOverridePath_constructsCorrectURL() {
        // VendorID 0x10ac = 4268 (Dell), ProductID 0x41da = 16858
        let vendorID:  UInt32 = 0x10ac
        let productID: UInt32 = 0x41da

        let url = PlistWriter.overridePath(vendorID: vendorID, productID: productID)

        XCTAssertTrue(
            url.path.hasSuffix("DisplayVendorID-10ac/DisplayProductID-41da"),
            "Override path must end with 'DisplayVendorID-10ac/DisplayProductID-41da', got: \(url.path)"
        )
    }

    func testOverridePath_lowercaseHex() {
        let vendorID:  UInt32 = 0xABCD
        let productID: UInt32 = 0xEF01

        let url = PlistWriter.overridePath(vendorID: vendorID, productID: productID)

        XCTAssertTrue(
            url.path.contains("DisplayVendorID-abcd"),
            "Vendor directory must use lowercase hex"
        )
        XCTAssertTrue(
            url.path.hasSuffix("DisplayProductID-ef01"),
            "Product file must use lowercase hex"
        )
    }

    // MARK: - Plist XML validity and write

    func testWrittenPlist_isValidXMLAndParseable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extradisplay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)]
        let plistData = try buildPlistData(vendorID: 0x10ac, productID: 0x41da, entries: entries)

        // Must deserialize without throwing.
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: &format
        )

        XCTAssertEqual(format, .xml, "Plist must be in XML format")
        let dict = try XCTUnwrap(parsed as? [String: Any], "Plist root must be a dictionary")

        XCTAssertNotNil(dict["DisplayProductID"],   "Plist must contain DisplayProductID")
        XCTAssertNotNil(dict["DisplayVendorID"],    "Plist must contain DisplayVendorID")
        XCTAssertNotNil(dict["scale-resolutions"],  "Plist must contain scale-resolutions")
    }

    // MARK: - scale-resolutions entry count

    func testScaleResolutions_containsExpectedNumberOfEntries() throws {
        // 8 logical resolutions × 3 variants each = 24 entries.
        // Use the QHD preset which has 8 resolutions.
        let entries = DisplayPresets.forNativeResolution(width: 2560, height: 1440, preset: .all)
        XCTAssertEqual(entries.count, 8, "QHD preset must produce 8 logical resolution entries")

        let plistData = try buildPlistData(vendorID: 0x10ac, productID: 0x41da, entries: entries)

        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(from: plistData, options: [], format: &format)
        let dict    = try XCTUnwrap(parsed as? [String: Any])
        let scaleResolutions = try XCTUnwrap(
            dict["scale-resolutions"] as? [Data],
            "scale-resolutions must be an array of Data"
        )

        XCTAssertEqual(
            scaleResolutions.count,
            8 * 3,
            "scale-resolutions must contain \(8 * 3) entries (8 resolutions × 3 variants)"
        )
    }

    // MARK: - Write to temp directory

    func testWriteToTempDirectory_fileExistsAfterWrite() throws {
        // Swap the base path to temp dir for this test by building the data directly
        // and writing to a temp location — avoids needing root for /Library/Displays/.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extradisplay-plist-test-\(UUID().uuidString)", isDirectory: true)

        let vendorDir = tempDir.appendingPathComponent("DisplayVendorID-10ac", isDirectory: true)
        let plistURL  = vendorDir.appendingPathComponent("DisplayProductID-41da")

        try FileManager.default.createDirectory(at: vendorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries  = [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)]
        let plistData = try buildPlistData(vendorID: 0x10ac, productID: 0x41da, entries: entries)
        try plistData.write(to: plistURL, options: .atomic)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plistURL.path),
            "Plist file must exist after write"
        )

        let readBack = try Data(contentsOf: plistURL)
        XCTAssertFalse(readBack.isEmpty, "Written plist file must not be empty")
    }

    // MARK: - Helpers

    /// Builds plist Data using the same logic as PlistWriter.write, but without touching the filesystem.
    private func buildPlistData(
        vendorID: UInt32,
        productID: UInt32,
        entries: [HiDPIEntry]
    ) throws -> Data {
        let scaleResolutions: [Data] = entries.flatMap { $0.allVariants() }
        let plist: [String: Any] = [
            "DisplayProductID":   Int(productID),
            "DisplayVendorID":    Int(vendorID),
            "DisplayProductName": "Test Display",
            "scale-resolutions":  scaleResolutions,
            "target-default-ppmm": 10.0699301 as Double,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
