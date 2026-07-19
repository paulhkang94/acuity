import XCTest
@testable import acuity

/// Tests for `ResolutionController.selectModeIndex` — the logic that maps a
/// requested "looks like" size to the right display mode.
///
/// The key behaviors: pick the HiDPI variant (not a plain 1× mode) of the
/// requested logical size, never pick a non-desktop-usable mode, and break
/// ties by refresh rate. Mirrors the live S2721DGF mode set.
final class SetResolutionTests: XCTestCase {

    /// Mirrors the verified live modes: each logical size has a HiDPI variant,
    /// plus a competing 1× mode and a low-refresh duplicate.
    private func liveModes() -> [ModeCandidate] {
        [
            ModeCandidate(width: 2048, height: 1152, isHiDPI: true,  refreshRate: 144, usableForDesktopGUI: true),  // 0
            ModeCandidate(width: 1920, height: 1080, isHiDPI: true,  refreshRate: 144, usableForDesktopGUI: true),  // 1
            ModeCandidate(width: 1920, height: 1080, isHiDPI: false, refreshRate: 144, usableForDesktopGUI: true),  // 2 (1× competitor)
            ModeCandidate(width: 1920, height: 1080, isHiDPI: true,  refreshRate: 60,  usableForDesktopGUI: true),  // 3 (low refresh)
            ModeCandidate(width: 1440, height: 810,  isHiDPI: true,  refreshRate: 144, usableForDesktopGUI: true),  // 4
            ModeCandidate(width: 800,  height: 450,  isHiDPI: true,  refreshRate: 144, usableForDesktopGUI: false), // 5 (not usable)
        ]
    }

    func test_selectModeIndex_picksHiDPIVariant_overOneXOfSameSize() {
        let idx = ResolutionController.selectModeIndex(targetWidth: 1920, targetHeight: 1080, from: liveModes())
        XCTAssertEqual(idx, 1, "Must pick the 144Hz HiDPI 1920×1080 (index 1), not the 1× competitor or 60Hz one")
    }

    func test_selectModeIndex_breaksTiesByRefreshRate() {
        let modes = [
            ModeCandidate(width: 1440, height: 810, isHiDPI: true, refreshRate: 60,  usableForDesktopGUI: true),
            ModeCandidate(width: 1440, height: 810, isHiDPI: true, refreshRate: 144, usableForDesktopGUI: true),
        ]
        let idx = ResolutionController.selectModeIndex(targetWidth: 1440, targetHeight: 810, from: modes)
        XCTAssertEqual(idx, 1, "Among HiDPI matches, the 144Hz one wins")
    }

    func test_selectModeIndex_findsLargestUsableTarget() {
        let idx = ResolutionController.selectModeIndex(targetWidth: 2048, targetHeight: 1152, from: liveModes())
        XCTAssertEqual(idx, 0, "2048×1152 HiDPI is index 0")
    }

    func test_selectModeIndex_returnsNil_whenOnlyNonUsableMatch() {
        let idx = ResolutionController.selectModeIndex(targetWidth: 800, targetHeight: 450, from: liveModes())
        XCTAssertNil(idx, "800×450 is present but not desktop-usable — must not be selectable")
    }

    func test_selectModeIndex_returnsNil_whenSizeAbsent() {
        let idx = ResolutionController.selectModeIndex(targetWidth: 3000, targetHeight: 2000, from: liveModes())
        XCTAssertNil(idx, "A size not in the mode list must return nil")
    }

    func test_selectModeIndex_picksOneX_whenNoHiDPIVariantExists() {
        let modes = [
            ModeCandidate(width: 1024, height: 768, isHiDPI: false, refreshRate: 60, usableForDesktopGUI: true),
        ]
        let idx = ResolutionController.selectModeIndex(targetWidth: 1024, targetHeight: 768, from: modes)
        XCTAssertEqual(idx, 0, "Falls back to a 1× mode when that's the only match")
    }

    // MARK: - preferHiDPI: false (the "Acuity off" / soft comparison)

    func test_selectModeIndex_preferHiDPIfalse_picksOneXVariant() {
        // Same logical size has both HiDPI (idx 1) and 1× (idx 2). With
        // preferHiDPI=false we want the 1× soft variant — the no-acuity look.
        let idx = ResolutionController.selectModeIndex(
            targetWidth: 1920, targetHeight: 1080, preferHiDPI: false, from: liveModes()
        )
        XCTAssertEqual(idx, 2, "preferHiDPI:false must pick the 1× variant (index 2), not the HiDPI one")
    }

    func test_selectModeIndex_preferHiDPIfalse_fallsBackToHiDPI_whenNoOneX() {
        // Only a HiDPI variant exists → still return it rather than nil.
        let modes = [
            ModeCandidate(width: 1280, height: 720, isHiDPI: true, refreshRate: 144, usableForDesktopGUI: true),
        ]
        let idx = ResolutionController.selectModeIndex(
            targetWidth: 1280, targetHeight: 720, preferHiDPI: false, from: modes
        )
        XCTAssertEqual(idx, 0, "With no 1× variant, falls back to the HiDPI mode")
    }

    // MARK: - targetHz (remembered refresh rate)

    func test_selectModeIndex_targetHz_picksExactHz_overHigherHz() {
        let modes = [
            ModeCandidate(width: 1600, height: 900, isHiDPI: true, refreshRate: 144, usableForDesktopGUI: true),
            ModeCandidate(width: 1600, height: 900, isHiDPI: true, refreshRate: 120, usableForDesktopGUI: true),
            ModeCandidate(width: 1600, height: 900, isHiDPI: true, refreshRate: 60,  usableForDesktopGUI: true),
        ]
        let result = ResolutionController.selectModeIndex(
            targetWidth: 1600, targetHeight: 900, targetHz: 120, from: modes
        )
        XCTAssertEqual(result.index, 1, "targetHz:120 must pick the 120Hz mode, not the 144Hz tiebreak winner")
        XCTAssertFalse(result.hzFellBack)
    }

    func test_selectModeIndex_targetHzAbsent_fallsBackToResPool_andReportsIt() {
        // Remembered 144Hz, but only 60/120 available right now (e.g. transient
        // dock enumeration) → apply the resolution anyway at the pool's best Hz
        // and surface hzFellBack so the caller can log.
        let modes = [
            ModeCandidate(width: 1600, height: 900, isHiDPI: true, refreshRate: 60,  usableForDesktopGUI: true),
            ModeCandidate(width: 1600, height: 900, isHiDPI: true, refreshRate: 120, usableForDesktopGUI: true),
        ]
        let result = ResolutionController.selectModeIndex(
            targetWidth: 1600, targetHeight: 900, targetHz: 144, from: modes
        )
        XCTAssertEqual(result.index, 1, "Hz miss must fall back to the res pool's best (120Hz)")
        XCTAssertTrue(result.hzFellBack, "Fallback must be reported so callers can log it")
    }

    func test_selectModeIndex_targetHz_resMiss_returnsNil_notFellBack() {
        let result = ResolutionController.selectModeIndex(
            targetWidth: 3000, targetHeight: 2000, targetHz: 120, from: liveModes()
        )
        XCTAssertNil(result.index, "A resolution miss still returns nil — hz never rescues a res miss")
        XCTAssertFalse(result.hzFellBack)
    }

    func test_selectModeIndex_targetHz_restrictsBeforeHiDPITiebreak() {
        // Pin the ordering: the Hz restriction happens FIRST, then the HiDPI
        // preference applies within the Hz-matching pool. An exact-Hz 1× mode
        // beats an off-Hz HiDPI mode — the pinned Hz is an explicit request.
        let modes = [
            ModeCandidate(width: 1600, height: 900, isHiDPI: true,  refreshRate: 144, usableForDesktopGUI: true),
            ModeCandidate(width: 1600, height: 900, isHiDPI: false, refreshRate: 120, usableForDesktopGUI: true),
        ]
        let result = ResolutionController.selectModeIndex(
            targetWidth: 1600, targetHeight: 900, targetHz: 120, preferHiDPI: true, from: modes
        )
        XCTAssertEqual(result.index, 1, "Exact-Hz 1× wins over off-Hz HiDPI (Hz pool restricts first)")
        XCTAssertFalse(result.hzFellBack)
    }

    func test_selectModeIndex_targetHzZero_treatedAsUnpinned() {
        // Virtual displays report 0 Hz; a stored/passed 0 must behave like nil.
        let result = ResolutionController.selectModeIndex(
            targetWidth: 1920, targetHeight: 1080, targetHz: 0, from: liveModes()
        )
        XCTAssertEqual(result.index, 1, "Hz 0 is unpinned — same pick as the no-Hz path")
        XCTAssertFalse(result.hzFellBack, "Hz 0 must not count as a fallback")
    }

    func test_selectModeIndex_targetHzNil_matchesLegacyBehavior() {
        let legacy = ResolutionController.selectModeIndex(
            targetWidth: 1920, targetHeight: 1080, from: liveModes()
        )
        let result = ResolutionController.selectModeIndex(
            targetWidth: 1920, targetHeight: 1080, targetHz: nil, from: liveModes()
        )
        XCTAssertEqual(result.index, legacy)
        XCTAssertFalse(result.hzFellBack)
    }
}
