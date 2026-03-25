import Foundation

/// Wraps the private BezelServices framework to show the native macOS brightness OSD.
/// Falls back to no-op if BezelServices is unavailable (e.g., future macOS versions).
public struct BezelOverlay {

    // MARK: - Private framework handle

    private typealias BSDoGraphicFn = @convention(c) (Int, UInt32, UInt32, Float, Int) -> Void

    private static let _handle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/BezelServices.framework/BezelServices",
            RTLD_GLOBAL
        )
    }()

    // MARK: - Public API

    /// Shows the standard brightness OSD at `level` (0.0–1.0).
    /// Clamps out-of-range values to 0–1. No-op if BezelServices is unavailable.
    public static func showBrightness(_ level: Float) {
        let clamped = min(1.0, max(0.0, level))
        guard let handle = _handle,
              let sym = dlsym(handle, "BSDoGraphicWithMeterAndTimeout") else { return }
        let fn = unsafeBitCast(sym, to: BSDoGraphicFn.self)
        fn(0, 0x00000007, 0, clamped, 1) // graphic type 7 = brightness
    }
}
