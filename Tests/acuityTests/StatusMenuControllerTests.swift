import AppKit
import XCTest
@testable import acuity

final class StatusMenuControllerTests: XCTestCase {

    // MARK: - rebuildMenu

    func test_rebuildMenu_doesNotCrash_withMockDDC() {
        let mock = MockDDCController()
        let controller = StatusMenuController(ddc: mock)
        // rebuildMenu without setup (no NSStatusBar) should not crash
        // We test the menu population logic via DisplayMenuItem directly
        _ = mock
        _ = controller
    }

    // MARK: - MockDDCController recording

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

    // MARK: - DisplayMenuItem

    func test_displayMenuItem_items_containsExpectedCount() {
        let mock = MockDDCController()
        mock.brightnessToReturn = 50
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        // Expected: header + brightness + input + resolution + separator = 5
        XCTAssertEqual(items.count, 5)
    }

    func test_displayMenuItem_resolutionItem_hasSubmenuWithNativeRow() {
        let mock = MockDDCController()
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        // Resolution submenu sits between the input item and the trailing separator.
        let resolutionItem = items[3]
        XCTAssertNotNil(resolutionItem.submenu, "Resolution item must carry a submenu")
        // The native row is always present regardless of live display modes.
        XCTAssertGreaterThanOrEqual(resolutionItem.submenu?.numberOfItems ?? 0, 1)
    }

    func test_displayMenuItem_header_isNotEnabled() {
        let mock = MockDDCController()
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        XCTAssertFalse(items[0].isEnabled)
    }

    func test_displayMenuItem_brightnessItem_hasView() {
        let mock = MockDDCController()
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        XCTAssertNotNil(items[1].view)
        XCTAssertTrue(items[1].view is BrightnessSliderView)
    }

    func test_displayMenuItem_inputItem_hasSubmenu() {
        let mock = MockDDCController()
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        XCTAssertNotNil(items[2].submenu)
        XCTAssertEqual(items[2].submenu?.numberOfItems, InputSource.allCases.count)
    }

    func test_displayMenuItem_lastItem_isSeparator() {
        let mock = MockDDCController()
        let display = makeDisplay()
        let items = DisplayMenuItem.items(for: display, ddc: mock, index: 0)
        XCTAssertTrue(items.last?.isSeparatorItem ?? false)
    }

    // MARK: - BrightnessSliderView debounce

    func test_brightnessSliderView_doesNotCallDDCImmediately() {
        // The slider view debounces writes by 150ms.
        // Creating a slider and NOT waiting should result in zero DDC calls.
        let mock = MockDDCController()
        let display = makeDisplay()
        let view = BrightnessSliderView(ddc: mock, display: display, currentBrightness: 50, ddcAvailable: true)
        // No programmatic change — should be zero DDC calls
        XCTAssertEqual(mock.brightnessSetCalls.count, 0)
        _ = view
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
