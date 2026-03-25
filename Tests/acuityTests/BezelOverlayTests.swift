import XCTest
@testable import acuity

/// BezelServices may not be available in CI — these tests verify that showBrightness
/// never crashes regardless of framework availability.
final class BezelOverlayTests: XCTestCase {
    func test_showBrightness_doesNotCrash_whenBezelServicesAbsent() {
        // Should be a no-op, not a crash
        BezelOverlay.showBrightness(0.5)
    }

    func test_showBrightness_belowZero_doesNotCrash() {
        BezelOverlay.showBrightness(-0.1)
    }

    func test_showBrightness_aboveOne_doesNotCrash() {
        BezelOverlay.showBrightness(1.5)
    }

    func test_showBrightness_zero_doesNotCrash() {
        BezelOverlay.showBrightness(0.0)
    }

    func test_showBrightness_one_doesNotCrash() {
        BezelOverlay.showBrightness(1.0)
    }
}
