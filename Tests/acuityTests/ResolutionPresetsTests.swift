import XCTest
@testable import acuity

/// Tests for `DisplayPresets.forNativeResolution` — the ladder generator that
/// turns a detected native resolution into the set of HiDPI scaled modes.
///
/// This is the payoff of correct native detection: feeding the true panel
/// native (2560×1440) yields the full QHD ladder of gatekept HiDPI modes,
/// whereas the misdetected 1920×1080 yielded a degraded ladder missing the
/// most useful "more space" retina modes. These tests pin both.
final class ResolutionPresetsTests: XCTestCase {

    private func logicalPairs(_ entries: [HiDPIEntry]) -> [[Int]] {
        entries.map { [$0.logicalWidth, $0.logicalHeight] }
    }

    // MARK: - QHD 2560×1440 (correct native after fix)

    func test_qhd_allPreset_returnsFullGatekeptLadder() {
        let entries = DisplayPresets.forNativeResolution(width: 2560, height: 1440, preset: .all)
        let pairs = logicalPairs(entries)

        // The full QHD ladder: the resolutions macOS gatekeeps for non-Apple panels.
        XCTAssertEqual(entries.count, 9, "QHD native must produce the full 9-rung ladder")
        XCTAssertTrue(pairs.contains([2560, 1440]), "Must offer native-as-HiDPI (renders 5120×2880 supersampled)")
        XCTAssertTrue(pairs.contains([2048, 1152]), "Must offer the 2048×1152 'more space' retina mode")
        XCTAssertTrue(pairs.contains([1920, 1080]), "Must offer the 1920×1080 HiDPI sweet spot")
        XCTAssertTrue(pairs.contains([1680, 945]),  "Must offer 1680×945")
        XCTAssertTrue(pairs.contains([1600, 900]),  "Must offer 1600×900 (renders 3200×1800 supersampled, the BetterDisplay-parity mode)")
        XCTAssertTrue(pairs.contains([1440, 810]),  "Must offer 1440×810")
    }

    func test_qhd_twoXPreset_returnsHalfNative_notBuggy960x540() {
        let entries = DisplayPresets.forNativeResolution(width: 2560, height: 1440, preset: .twoX)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].logicalWidth, 1280, "2× of 2560×1440 is 1280×720")
        XCTAssertEqual(entries[0].logicalHeight, 720)
        // Regression guard: the misdetected-native bug produced 960×540 here.
        XCTAssertFalse(entries[0].logicalWidth == 960 && entries[0].logicalHeight == 540,
            "Must not produce 960×540 (the value the 1920×1080 misdetection caused)")
    }

    // MARK: - The degraded ladder the bug produced (documents impact)

    func test_misdetected1080p_allPreset_isMissingTheBestModes() {
        // This is what `enable --preset all` wrote when native was misdetected as 1080p.
        let entries = DisplayPresets.forNativeResolution(width: 1920, height: 1080, preset: .all)
        let pairs = logicalPairs(entries)

        XCTAssertFalse(pairs.contains([2560, 1440]), "1080p ladder lacks the 2560×1440 retina mode — the regression")
        XCTAssertFalse(pairs.contains([2048, 1152]), "1080p ladder lacks 2048×1152")
        XCTAssertFalse(pairs.contains([1440, 810]),  "1080p ladder lacks 1440×810")
        XCTAssertLessThan(entries.count, 9, "Degraded ladder is strictly smaller than the QHD ladder")
    }

    // MARK: - 4K UHD 3840×2160

    func test_4k_allPreset_includesKeyScaledModes() {
        let entries = DisplayPresets.forNativeResolution(width: 3840, height: 2160, preset: .all)
        let pairs = logicalPairs(entries)
        XCTAssertTrue(pairs.contains([2560, 1440]), "4K ladder must offer the 2560×1440 HiDPI sweet spot")
        XCTAssertTrue(pairs.contains([1920, 1080]), "4K ladder must offer 1920×1080 HiDPI")
    }

    // MARK: - Unknown native falls back to a computed ladder

    func test_unknownNative_fallsBackToComputedLadder() {
        // 3440×1440 ultrawide is in the table; pick a truly arbitrary one for the fallback path.
        let entries = DisplayPresets.forNativeResolution(width: 3000, height: 2000, preset: .all)
        XCTAssertFalse(entries.isEmpty, "Arbitrary native must still produce a computed ladder")
        for e in entries {
            XCTAssertGreaterThanOrEqual(e.logicalWidth, 640, "Computed rungs must respect the 640 min width")
            XCTAssertGreaterThanOrEqual(e.logicalHeight, 400, "Computed rungs must respect the 400 min height")
        }
    }
}
