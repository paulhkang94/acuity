import AppKit
import XCTest
@testable import acuity

final class StatusMenuControllerTests: XCTestCase {

    // MARK: - StatusMenuController

    func test_statusMenuController_initsWithoutDDC() {
        // The menubar no longer depends on DDC — it must construct with no args.
        let controller = StatusMenuController()
        _ = controller
    }

    // MARK: - MockDDCController / DDC protocol
    //
    // DDC is removed from the menubar but still backs the CLI brightness /
    // contrast / input commands, so the protocol + mock stay covered.

    func test_mockDDC_recordsBrightnessSet() throws {
        let mock = MockDDCController()
        let display = makeDisplay()
        try mock.setBrightness(75, display: display)
        XCTAssertEqual(mock.brightnessSetCalls.count, 1)
        XCTAssertEqual(mock.brightnessSetCalls[0].0, 75)
    }

    func test_mockDDC_returnsBrightnessToReturn() throws {
        let mock = MockDDCController()
        mock.brightnessToReturn = 42
        let display = makeDisplay()
        let result = try mock.getBrightness(display: display)
        XCTAssertEqual(result, 42)
    }

    func test_mockDDC_recordsContrastSet() throws {
        let mock = MockDDCController()
        let display = makeDisplay()
        try mock.setContrast(60, display: display)
        XCTAssertEqual(mock.contrastSetCalls.count, 1)
        XCTAssertEqual(mock.contrastSetCalls[0].0, 60)
    }

    func test_mockDDC_recordsInputSet() throws {
        let mock = MockDDCController()
        let display = makeDisplay()
        try mock.setInput(.hdmi1, display: display)
        XCTAssertEqual(mock.inputSetCalls.count, 1)
        XCTAssertEqual(mock.inputSetCalls[0].0, .hdmi1)
    }

    func test_mockDDC_throwsWhenShouldThrowSet() {
        let mock = MockDDCController()
        mock.shouldThrow = DDCError.serviceUnavailable("test")
        let display = makeDisplay()
        XCTAssertThrowsError(try mock.setBrightness(50, display: display))
        XCTAssertThrowsError(try mock.getBrightness(display: display))
        XCTAssertThrowsError(try mock.setContrast(50, display: display))
        XCTAssertThrowsError(try mock.setInput(.hdmi1, display: display))
    }

    // MARK: - DisplayMenuItem (DDC-stripped: header + resolution + separator)

    func test_displayMenuItem_items_containsExpectedCount() {
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, index: 0)
        // After the DDC strip: header + resolution + separator = 3.
        XCTAssertEqual(items.count, 3)
    }

    func test_displayMenuItem_header_isNotEnabled() {
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, index: 0)
        XCTAssertFalse(items[0].isEnabled)
    }

    func test_displayMenuItem_resolutionItem_hasSubmenuWithNativeRow() {
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, index: 0)
        // Resolution submenu now sits at index 1 (header, resolution, separator).
        let resolutionItem = items[1]
        XCTAssertNotNil(resolutionItem.submenu, "Resolution item must carry a submenu")
        // The native row is always present regardless of live display modes.
        XCTAssertGreaterThanOrEqual(resolutionItem.submenu?.numberOfItems ?? 0, 1)
    }

    func test_displayMenuItem_lastItem_isSeparator() {
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, index: 0)
        XCTAssertTrue(items.last?.isSeparatorItem ?? false)
    }

    /// Regression guard for the DDC strip: no brightness slider view, and the
    /// resolution submenu is the only submenu (no input submenu creeps back).
    func test_displayMenuItem_hasNoBrightnessOrInputRows() {
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, index: 0)
        XCTAssertNil(items.first(where: { $0.view != nil }), "No brightness slider view should remain")
        XCTAssertEqual(items.filter { $0.submenu != nil }.count, 1, "Only the resolution submenu should remain")
    }

    // MARK: - Helpers

    private func makeDisplay(isBuiltIn: Bool = false) -> DisplayInfo {
        DisplayInfo(
            vendorID: 0x1234,
            productID: 0x5678,
            displayID: 1,
            name: "Test Display",
            nativeWidth: 2560,
            nativeHeight: 1440,
            isBuiltIn: isBuiltIn,
            connectionType: .displayPort
        )
    }
}
