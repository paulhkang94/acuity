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

    // MARK: - DisplayMenuItem (header + resolution + separator)

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
