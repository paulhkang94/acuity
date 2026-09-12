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

    func test_menuOpen_enumeratesOnceOnMainForEachFreshOpen() {
        var enumerations = 0
        let controller = StatusMenuController(enumerateDisplays: {
            XCTAssertTrue(Thread.isMainThread, "Menu inventory must stay on the AppKit thread")
            enumerations += 1
            return []
        })
        let menu = NSMenu()

        controller.menuWillOpen(menu)
        XCTAssertEqual(enumerations, 1, "One menu open needs only one topology snapshot")
        controller.menuWillOpen(menu)
        XCTAssertEqual(enumerations, 2, "Each later open must still obtain a fresh snapshot")
    }

    func test_enableAll_preservesRememberedHzWhenItFallsBack() throws {
        let store = makeStore()
        let display = makeDisplay()
        try store.record(vendorID: display.vendorID, productID: display.productID,
                         width: 1920, height: 1080, hz: 120)

        let result = StatusMenuController().applyHiDPILiveToAllExternals(
            displays: [display], store: store
        ) { received, width, height, hz in
            XCTAssertEqual(received.displayID, display.displayID)
            XCTAssertEqual(width, 1920)
            XCTAssertEqual(height, 1080)
            XCTAssertEqual(hz, 120)
            return (60, true)
        }

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.applied, 1, "A refresh-rate fallback still applies HiDPI successfully")
        XCTAssertEqual(store.selection(vendorID: display.vendorID, productID: display.productID),
                       SelectionStore.Selection(width: 1920, height: 1080, hz: 120),
                       "A temporary rate limit must not replace the requested rate for reconnect")
    }

    func test_enableAll_recordsAppliedHzWithoutFallback() throws {
        let store = makeStore()
        let display = makeDisplay()
        for (refreshRate, expectedHz) in [(119.88, Optional(120)), (0, nil)] {
            try store.record(vendorID: display.vendorID, productID: display.productID,
                             width: 1920, height: 1080, hz: nil)
            let result = StatusMenuController().applyHiDPILiveToAllExternals(
                displays: [display], store: store
            ) { _, _, _, hz in
                XCTAssertNil(hz)
                return (refreshRate, false)
            }
            XCTAssertEqual(result.applied, 1)
            XCTAssertEqual(store.selection(vendorID: display.vendorID, productID: display.productID)?.hz,
                           expectedHz)
        }
    }

    func test_enableAll_failedApplyPreservesSelectionAndDoesNotCountSuccess() throws {
        let store = makeStore()
        let display = makeDisplay()
        try store.record(vendorID: display.vendorID, productID: display.productID,
                         width: 1920, height: 1080, hz: 120)
        let result = StatusMenuController().applyHiDPILiveToAllExternals(
            displays: [display, makeDisplay(isBuiltIn: true)], store: store
        ) { _, _, _, _ in
            throw NSError(domain: "AcuityTest", code: 1)
        }
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(store.selection(vendorID: display.vendorID, productID: display.productID)?.hz, 120)
    }

    private func makeStore() -> SelectionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acuity-menu-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SelectionStore(fileURL: directory.appendingPathComponent("selections.json"))
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
