import XCTest
@testable import acuity

/// Tests for `SelectionStore` — the per-display remembered-resolution store the
/// daemon reads to re-apply the user's chosen size instead of the largest HiDPI.
///
/// Keyed by vendor:product (stable across reboots), so two identical monitors
/// share one remembered size — which is exactly the desired behavior for a
/// matched pair like the dual Dell S2721DGFs.
final class SelectionStoreTests: XCTestCase {

    private var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("acuity-selstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("selected-resolutions.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
        super.tearDown()
    }

    func test_record_thenSelection_roundTrips() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900))
    }

    func test_selection_unknownDisplay_returnsNil() {
        let store = SelectionStore(fileURL: tempFile)
        XCTAssertNil(store.selection(vendorID: 0x10ac, productID: 0x41da))
    }

    func test_record_overwrites_latestWins() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1680, height: 945)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900))
    }

    /// Integration: assert the bytes actually landed on disk, not just that the
    /// method returned — a daemon in a separate process reads this file fresh.
    func test_record_writesReadableJSONToDisk() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path),
                      "record() must persist a file to disk")
        let data = try Data(contentsOf: tempFile)
        let decoded = try JSONDecoder().decode([String: SelectionStore.Selection].self, from: data)
        XCTAssertEqual(decoded["10ac:41da"], SelectionStore.Selection(width: 1600, height: 900))
    }

    func test_distinctDisplays_areIndependent() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900)
        try store.record(vendorID: 0x0610, productID: 0xa034, width: 1440, height: 810)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900))
        XCTAssertEqual(store.selection(vendorID: 0x0610, productID: 0xa034),
                       SelectionStore.Selection(width: 1440, height: 810))
    }

    func test_key_isZeroPaddedLowercaseHex() {
        XCTAssertEqual(SelectionStore.key(vendorID: 0x10ac, productID: 0x41da), "10ac:41da")
        XCTAssertEqual(SelectionStore.key(vendorID: 0x0610, productID: 0x00a0), "0610:00a0")
    }

    /// A corrupt or partially-written store must read as empty, never crash the
    /// daemon — "no remembered choice" is a safe fallback.
    func test_corruptFile_readsAsEmpty_neverThrows() throws {
        try FileManager.default.createDirectory(
            at: tempFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: tempFile)

        let store = SelectionStore(fileURL: tempFile)
        XCTAssertNil(store.selection(vendorID: 0x10ac, productID: 0x41da))
        XCTAssertTrue(store.readAll().isEmpty)
    }
}
