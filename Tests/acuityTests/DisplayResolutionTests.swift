import CoreGraphics
import XCTest
@testable import acuity

/// Regression tests for native-resolution detection.
///
/// Bug (pre-fix): `DisplayEnumerator` read `CGDisplayBounds`, which returns
/// logical POINTS, not native pixels. On a 2560×1440 panel running a 2× HiDPI
/// mode ("looks like 1920×1080"), bounds report 1920×1080 — so acuity recorded
/// native = 1920×1080 and built the wrong (1080p) scaling ladder, denying the
/// user the QHD-derived HiDPI modes that are the whole point of the tool.
///
/// Ground truth captured live from two Dell S2721DGF (0x10ac:0x41da) panels:
///   CGDisplayBounds (points):        1920 × 1080   ← old, wrong
///   current mode pixels:             3840 × 2160   ← supersampled "more space"
///   max pixels over ALL modes:       4096 × 2304   ← supersampled, over-detects
///   max pixels among NATIVE-flagged: 2560 × 1440   ← correct panel native
///   max pixels among 1× modes:       2560 × 1440   ← corroborates
final class DisplayResolutionTests: XCTestCase {

    /// Synthetic mode set mirroring the live S2721DGF readout: a 2560×1440
    /// panel with native-flagged modes plus several HiDPI supersampled modes
    /// (pixel dimensions exceeding the panel) and low-res scaled modes.
    private func s2721dgfModes() -> [DisplayModeDescriptor] {
        [
            // Native-flagged modes (ioFlags has the native bit set). Largest = 2560×1440.
            DisplayModeDescriptor(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, ioFlags: DisplayEnumerator.nativeModeFlag),
            DisplayModeDescriptor(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, ioFlags: DisplayEnumerator.nativeModeFlag),
            DisplayModeDescriptor(pixelWidth: 1280, pixelHeight: 720,  pointWidth: 1280, ioFlags: DisplayEnumerator.nativeModeFlag),
            // Current mode: "looks like 1920×1080" HiDPI — framebuffer 3840×2160, NOT native-flagged.
            DisplayModeDescriptor(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, ioFlags: 0x3),
            // "More space" supersampled modes — pixels exceed the panel, NOT native-flagged.
            DisplayModeDescriptor(pixelWidth: 5120, pixelHeight: 2880, pointWidth: 2560, ioFlags: 0x0),
            DisplayModeDescriptor(pixelWidth: 4096, pixelHeight: 2304, pointWidth: 2048, ioFlags: 0x0),
            // Low-res 1× scaled mode.
            DisplayModeDescriptor(pixelWidth: 1024, pixelHeight: 576,  pointWidth: 1024, ioFlags: 0x0),
        ]
    }

    // MARK: - The core regression

    func test_selectNativeResolution_returnsPanelNative_notLogicalOrSupersampled() {
        let native = DisplayEnumerator.selectNativeResolution(from: s2721dgfModes())
        XCTAssertEqual(native?.width, 2560, "Native width must be the panel's 2560, not 1920 (points) or a supersampled value")
        XCTAssertEqual(native?.height, 1440, "Native height must be the panel's 1440")
    }

    func test_selectNativeResolution_ignoresSupersampledMoreSpaceModes() {
        // 5120×2880 and 4096×2304 have the largest pixel counts but are NOT native;
        // selecting by raw max pixels would wrongly pick them.
        let native = DisplayEnumerator.selectNativeResolution(from: s2721dgfModes())
        XCTAssertNotEqual(native?.width, 5120, "Must not pick the 5120×2880 supersampled mode")
        XCTAssertNotEqual(native?.width, 4096, "Must not pick the 4096×2304 supersampled mode")
    }

    func test_selectNativeResolution_doesNotReturnLogicalPointResolution() {
        // The old bug returned 1920×1080 (the current mode's point size).
        let native = DisplayEnumerator.selectNativeResolution(from: s2721dgfModes())
        XCTAssertFalse(native?.width == 1920 && native?.height == 1080,
            "Regression: must not return the 1920×1080 logical (points) resolution")
    }

    // MARK: - Fallback behavior

    func test_selectNativeResolution_fallsBackToOneXMode_whenNoNativeFlag() {
        // No native flag anywhere → fall back to largest 1× mode (pixelWidth == pointWidth).
        let modes = [
            DisplayModeDescriptor(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, ioFlags: 0x0), // 1× native panel
            DisplayModeDescriptor(pixelWidth: 5120, pixelHeight: 2880, pointWidth: 2560, ioFlags: 0x0), // supersampled, not 1×
            DisplayModeDescriptor(pixelWidth: 1280, pixelHeight: 720,  pointWidth: 1280, ioFlags: 0x0), // smaller 1×
        ]
        let native = DisplayEnumerator.selectNativeResolution(from: modes)
        XCTAssertEqual(native?.width, 2560)
        XCTAssertEqual(native?.height, 1440)
    }

    func test_selectNativeResolution_prefersNativeFlagOverLargerOneXMode() {
        // A native-flagged 2560×1440 must win even if a larger 1× mode exists.
        let modes = [
            DisplayModeDescriptor(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, ioFlags: DisplayEnumerator.nativeModeFlag),
            DisplayModeDescriptor(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 3840, ioFlags: 0x0), // larger, 1×, but not native-flagged
        ]
        let native = DisplayEnumerator.selectNativeResolution(from: modes)
        XCTAssertEqual(native?.width, 2560, "Native-flagged mode must take precedence over a larger non-native 1× mode")
    }

    func test_selectNativeResolution_returnsNil_forEmptyModeList() {
        XCTAssertNil(DisplayEnumerator.selectNativeResolution(from: []))
    }

    // MARK: - 4K panel sanity check

    func test_selectNativeResolution_4KPanel_returns3840x2160() {
        let modes = [
            DisplayModeDescriptor(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 3840, ioFlags: DisplayEnumerator.nativeModeFlag),
            DisplayModeDescriptor(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, ioFlags: DisplayEnumerator.nativeModeFlag),
            DisplayModeDescriptor(pixelWidth: 7680, pixelHeight: 4320, pointWidth: 3840, ioFlags: 0x0), // supersampled
        ]
        let native = DisplayEnumerator.selectNativeResolution(from: modes)
        XCTAssertEqual(native?.width, 3840)
        XCTAssertEqual(native?.height, 2160)
    }
}
