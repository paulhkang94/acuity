import XCTest
@testable import acuity

/// Regression tests for the "Current mode" line in `acuity status`.
///
/// Bug (pre-fix): `currentModeDescription` enumerated all modes and matched the
/// "current" one by `pixelWidth == nativeWidth`, then took `.first(where:)`.
/// Multiple modes share pixel dimensions (a 2560-pixel framebuffer is both a
/// 1× 2560×1440 mode and a 2× "looks like 1280×720" mode), so it reported an
/// arbitrary mode — e.g. "1280×720 @2×" — instead of the genuinely active one.
///
/// Ground truth (live): the displays run a "looks like 1920×1080" HiDPI mode —
/// point 1920×1080, framebuffer 3840×2160. The status line must say so.
final class CurrentModeDescriptionTests: XCTestCase {

    func test_describeMode_hiDPI_reportsLogicalPointSize_notNativeOrSupersampled() {
        // Active mode: looks-like 1920×1080, framebuffer 3840×2160 (2×), 144Hz.
        let desc = StatusCommand.describeMode(
            pointWidth: 1920, pointHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            hz: 144
        )
        XCTAssertTrue(desc.contains("1920×1080"), "Must report the active logical size 1920×1080, got: \(desc)")
        XCTAssertTrue(desc.contains("@2×"), "Framebuffer 3840 / point 1920 = 2× scale, got: \(desc)")
        XCTAssertTrue(desc.contains("HiDPI"), "Pixel > point means HiDPI active, got: \(desc)")
        XCTAssertTrue(desc.contains("144Hz"), "Refresh rate must appear, got: \(desc)")
    }

    func test_describeMode_doesNotReportArbitraryWrongMode() {
        // The old bug surfaced 1280×720 or 960×540 — modes that are NOT active.
        let desc = StatusCommand.describeMode(
            pointWidth: 1920, pointHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            hz: 144
        )
        XCTAssertFalse(desc.contains("1280×720"), "Regression: must not report the non-active 1280×720 mode")
        XCTAssertFalse(desc.contains("960×540"), "Regression: must not report the non-active 960×540 mode")
    }

    func test_describeMode_standard_whenPixelsEqualPoints() {
        // 1× mode: framebuffer == logical → Standard, not HiDPI.
        let desc = StatusCommand.describeMode(
            pointWidth: 2560, pointHeight: 1440,
            pixelWidth: 2560, pixelHeight: 1440,
            hz: 144
        )
        XCTAssertTrue(desc.contains("Standard"), "Equal pixel/point dims means Standard (1×), got: \(desc)")
        XCTAssertTrue(desc.contains("2560×1440"), "Must report 2560×1440, got: \(desc)")
        XCTAssertFalse(desc.contains("HiDPI"), "1× mode must not claim HiDPI, got: \(desc)")
    }

    func test_describeMode_omitsRefresh_whenNil() {
        let desc = StatusCommand.describeMode(
            pointWidth: 2560, pointHeight: 1440,
            pixelWidth: 2560, pixelHeight: 1440,
            hz: nil
        )
        XCTAssertFalse(desc.contains("Hz"), "No refresh rate must mean no 'Hz' in output, got: \(desc)")
    }
}
