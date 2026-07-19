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
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: nil)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900))
    }

    // MARK: - Refresh-rate (Hz) persistence

    func test_record_withHz_roundTrips() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: 120)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900, hz: 120))
    }

    /// Backward-compat contract: a store written by a pre-Hz binary (no "hz"
    /// key) must decode with `hz == nil` — meaning "apply resolution, leave the
    /// refresh rate alone", exactly the old behavior.
    func test_legacyFileWithoutHz_decodesWithNilHz() throws {
        try FileManager.default.createDirectory(
            at: tempFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = #"{"10ac:41da": {"width": 1600, "height": 900}}"#
        try Data(legacyJSON.utf8).write(to: tempFile)

        let store = SelectionStore(fileURL: tempFile)
        let sel = store.selection(vendorID: 0x10ac, productID: 0x41da)
        XCTAssertEqual(sel, SelectionStore.Selection(width: 1600, height: 900, hz: nil))
        XCTAssertNil(sel?.hz)
    }

    /// Integration: the "hz" key must actually land on disk — the daemon reads
    /// this file fresh in a separate process.
    func test_record_withHz_writesHzKeyToDisk() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: 120)

        let data = try Data(contentsOf: tempFile)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: [String: Int]])
        XCTAssertEqual(raw["10ac:41da"]?["hz"], 120)
    }

    /// Virtual displays report 0 Hz; storing 0 would make reconnects hunt for
    /// a nonexistent 0Hz mode. record() must normalize non-positive Hz to nil.
    func test_record_hzZero_normalizedToNil() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: 0)

        let sel = store.selection(vendorID: 0x10ac, productID: 0x41da)
        XCTAssertEqual(sel, SelectionStore.Selection(width: 1600, height: 900, hz: nil))
    }

    func test_selection_unknownDisplay_returnsNil() {
        let store = SelectionStore(fileURL: tempFile)
        XCTAssertNil(store.selection(vendorID: 0x10ac, productID: 0x41da))
    }

    func test_record_overwrites_latestWins() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1680, height: 945, hz: nil)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: nil)

        XCTAssertEqual(store.selection(vendorID: 0x10ac, productID: 0x41da),
                       SelectionStore.Selection(width: 1600, height: 900))
    }

    /// Integration: assert the bytes actually landed on disk, not just that the
    /// method returned — a daemon in a separate process reads this file fresh.
    func test_record_writesReadableJSONToDisk() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path),
                      "record() must persist a file to disk")
        let data = try Data(contentsOf: tempFile)
        let decoded = try JSONDecoder().decode([String: SelectionStore.Selection].self, from: data)
        XCTAssertEqual(decoded["10ac:41da"], SelectionStore.Selection(width: 1600, height: 900))
    }

    func test_distinctDisplays_areIndependent() throws {
        let store = SelectionStore(fileURL: tempFile)
        try store.record(vendorID: 0x10ac, productID: 0x41da, width: 1600, height: 900, hz: nil)
        try store.record(vendorID: 0x0610, productID: 0xa034, width: 1440, height: 810, hz: nil)

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
