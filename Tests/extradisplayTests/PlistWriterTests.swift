import XCTest
@testable import extradisplay

/// Tests for PlistWriter.
///
/// Critical Tier 2 requirement: tests must call PlistWriter.write() directly
/// (the real method), not a private helper — so we catch bugs in the actual
/// code path that runs when the user runs `extradisplay enable`.
final class PlistWriterTests: XCTestCase {

    // MARK: - Path construction

    func test_overridePath_formatsHexCorrectly_forDellS2721DGF() {
        // Dell VendorID 0x10ac = 4268, ProductID 0x41da = 16858
        let url = PlistWriter.overridePath(vendorID: 0x10ac, productID: 0x41da)
        XCTAssertTrue(url.path.hasSuffix("DisplayVendorID-10ac/DisplayProductID-41da"),
            "Path must end with DisplayVendorID-10ac/DisplayProductID-41da, got: \(url.path)")
    }

    func test_overridePath_usesLowercaseHex() {
        let url = PlistWriter.overridePath(vendorID: 0xABCD, productID: 0xEF01)
        XCTAssertTrue(url.path.contains("DisplayVendorID-abcd"),
            "Vendor directory must use lowercase hex")
        XCTAssertTrue(url.path.hasSuffix("DisplayProductID-ef01"),
            "Product filename must use lowercase hex")
    }

    // MARK: - PlistWriter.write() Tier 2: calls the real method, reads back from disk

    func test_write_createsFileOnDisk() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        try PlistWriter.write(
            vendorID: 0x10ac,
            productID: 0x41da,
            productName: "Test Dell",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )

        let plistURL = tempBase
            .appendingPathComponent("DisplayVendorID-10ac")
            .appendingPathComponent("DisplayProductID-41da")

        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path),
            "PlistWriter.write() must create the plist file on disk")
    }

    func test_write_producesValidXMLPlist() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Test Dell",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )

        let data = try readWrittenPlist(base: tempBase)
        var format = PropertyListSerialization.PropertyListFormat.xml
        XCTAssertNoThrow(
            try PropertyListSerialization.propertyList(from: data, options: [], format: &format),
            "Written plist must be valid XML deserializable by PropertyListSerialization"
        )
        XCTAssertEqual(format, .xml, "Output must be XML plist format")
    }

    func test_write_scaleResolutions_containsAppleCanonical12ByteEntries() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        let entries = [
            HiDPIEntry(logicalWidth: 1280, logicalHeight: 720),
            HiDPIEntry(logicalWidth: 1920, logicalHeight: 1080),
        ]
        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Test Dell",
            entries: entries, baseURL: tempBase
        )

        let dict = try readPlistDict(base: tempBase)
        let scaleResolutions = try XCTUnwrap(
            dict["scale-resolutions"] as? [Data],
            "scale-resolutions must be an array of Data in the written plist"
        )

        // With Apple canonical format (1 entry per resolution), expect entries.count entries
        XCTAssertEqual(scaleResolutions.count, entries.count,
            "scale-resolutions count must match number of HiDPIEntry objects")

        // Every entry must be exactly 12 bytes
        for (i, entry) in scaleResolutions.enumerated() {
            XCTAssertEqual(entry.count, 12,
                "scale-resolutions[\(i)] must be 12 bytes (Apple canonical format), got \(entry.count)")
        }
    }

    func test_write_scaleResolutions_firstEntry_matchesAppleCanonicalBytes() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Test Dell",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )

        let dict = try readPlistDict(base: tempBase)
        let scaleResolutions = try XCTUnwrap(dict["scale-resolutions"] as? [Data])
        let entry = scaleResolutions[0]

        // Apple canonical: physW=2560, physH=1440, flag=0x00000001
        let expectedBytes = Data([0x00,0x00,0x0A,0x00, 0x00,0x00,0x05,0xA0, 0x00,0x00,0x00,0x01])
        XCTAssertEqual(entry, expectedBytes,
            "First scale-resolutions entry must match Apple canonical bytes for 1280×720 HiDPI")
    }

    func test_write_plistContainsRequiredKeys() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Dell S2721DGF",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )

        let dict = try readPlistDict(base: tempBase)
        XCTAssertEqual(dict["DisplayVendorID"] as? Int, 4268,  "DisplayVendorID must be 4268 (0x10ac)")
        XCTAssertEqual(dict["DisplayProductID"] as? Int, 16858, "DisplayProductID must be 16858 (0x41da)")
        XCTAssertNotNil(dict["scale-resolutions"], "scale-resolutions key must be present")
    }

    func test_exists_returnsFalseBeforeWrite_trueAfterWrite() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        XCTAssertFalse(PlistWriter.exists(vendorID: 0x10ac, productID: 0x41da, baseURL: tempBase),
            "exists() must return false before write")

        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Test",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )

        XCTAssertTrue(PlistWriter.exists(vendorID: 0x10ac, productID: 0x41da, baseURL: tempBase),
            "exists() must return true after write")
    }

    func test_remove_deletesFile() throws {
        let tempBase = makeTempBase()
        defer { cleanup(tempBase) }

        try PlistWriter.write(
            vendorID: 0x10ac, productID: 0x41da, productName: "Test",
            entries: [HiDPIEntry(logicalWidth: 1280, logicalHeight: 720)],
            baseURL: tempBase
        )
        XCTAssertTrue(PlistWriter.exists(vendorID: 0x10ac, productID: 0x41da, baseURL: tempBase))

        try PlistWriter.remove(vendorID: 0x10ac, productID: 0x41da, baseURL: tempBase)

        XCTAssertFalse(PlistWriter.exists(vendorID: 0x10ac, productID: 0x41da, baseURL: tempBase),
            "exists() must return false after remove()")
    }

    // MARK: - Helpers

    private func makeTempBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extradisplay-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func readWrittenPlist(base: URL) throws -> Data {
        let url = base
            .appendingPathComponent("DisplayVendorID-10ac")
            .appendingPathComponent("DisplayProductID-41da")
        return try Data(contentsOf: url)
    }

    private func readPlistDict(base: URL) throws -> [String: Any] {
        let data = try readWrittenPlist(base: base)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return try XCTUnwrap(parsed as? [String: Any], "Plist root must be a dictionary")
    }
}
