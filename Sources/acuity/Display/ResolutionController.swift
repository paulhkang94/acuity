import CoreGraphics
import Foundation

/// A CoreGraphics-free snapshot of a candidate mode, for pure selection logic.
struct ModeCandidate {
    let width: Int          // logical (point) width — the "looks like" size
    let height: Int         // logical (point) height
    let isHiDPI: Bool        // pixelWidth > width
    let refreshRate: Int
    let usableForDesktopGUI: Bool
}

/// Switches displays between resolution modes at runtime (no reboot) using the
/// public CoreGraphics display-configuration APIs. Shared by the
/// `set-resolution` command and the menubar so both apply modes identically.
enum ResolutionController {

    /// One selectable "looks like" size for a display.
    struct LooksLikeMode {
        let width: Int
        let height: Int
        let framebufferWidth: Int
        let framebufferHeight: Int
        let refreshRate: Int
        let isHiDPI: Bool

        /// Zoom relative to a native width, e.g. 125 for 2048 on a 2560-wide panel.
        func zoomPercent(nativeWidth: Int) -> Int {
            guard width > 0 else { return 100 }
            return Int((Double(nativeWidth) / Double(width) * 100).rounded())
        }
    }

    // MARK: - Enumeration

    static func allModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    /// Deduped HiDPI "looks like" sizes, largest logical area first.
    static func hiDPISizes(for displayID: CGDirectDisplayID) -> [LooksLikeMode] {
        var seen = Set<String>()
        var out: [LooksLikeMode] = []
        let modes = allModes(for: displayID)
            .filter { $0.pixelWidth > $0.width && $0.isUsableForDesktopGUI() }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        for m in modes {
            let key = "\(m.width)x\(m.height)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(LooksLikeMode(
                width: m.width, height: m.height,
                framebufferWidth: m.pixelWidth, framebufferHeight: m.pixelHeight,
                refreshRate: Int(m.refreshRate.rounded()), isHiDPI: true
            ))
        }
        return out
    }

    /// Deduped 1× (non-HiDPI) sizes at or above `minWidth`, largest first.
    /// These are the soft, panel-upscaled modes you get *without* acuity —
    /// used to demonstrate the sharpness difference at a matching size.
    static func oneXSizes(for displayID: CGDirectDisplayID, minWidth: Int = 1600) -> [LooksLikeMode] {
        var seen = Set<String>()
        var out: [LooksLikeMode] = []
        let modes = allModes(for: displayID)
            .filter { $0.pixelWidth == $0.width && $0.isUsableForDesktopGUI() && $0.width >= minWidth }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        for m in modes {
            let key = "\(m.width)x\(m.height)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(LooksLikeMode(
                width: m.width, height: m.height,
                framebufferWidth: m.pixelWidth, framebufferHeight: m.pixelHeight,
                refreshRate: Int(m.refreshRate.rounded()), isHiDPI: false
            ))
        }
        return out
    }

    static func currentMode(for displayID: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(displayID)
    }

    // MARK: - Pure selection logic (testable)

    /// Returns the index of the best mode matching the requested logical size.
    ///
    /// Only desktop-usable modes are eligible. When `preferHiDPI` is true,
    /// prefers a HiDPI mode over a 1× mode of the same logical size (so "looks
    /// like 1920×1080" picks the retina framebuffer, not a plain 1920×1080),
    /// then the highest refresh rate. When false, prefers the 1× (soft) variant
    /// — used to demonstrate the difference acuity's HiDPI scaling makes.
    static func selectModeIndex(
        targetWidth: Int,
        targetHeight: Int,
        preferHiDPI: Bool = true,
        from modes: [ModeCandidate]
    ) -> Int? {
        selectModeIndex(
            targetWidth: targetWidth, targetHeight: targetHeight,
            targetHz: nil, preferHiDPI: preferHiDPI, from: modes
        ).index
    }

    /// Hz-aware variant. When `targetHz` is set (and > 0 — virtual displays
    /// report 0 Hz, treated as unpinned), the resolution-matched pool is first
    /// restricted to modes at exactly that refresh rate; the HiDPI/refresh
    /// tiebreaks then run within that pool. If no mode matches the pinned Hz,
    /// the full resolution pool is used instead (the pre-Hz behavior) and
    /// `hzFellBack` is true so callers can log — an Hz miss never turns a
    /// resolvable resolution into a failure.
    static func selectModeIndex(
        targetWidth: Int,
        targetHeight: Int,
        targetHz: Int?,
        preferHiDPI: Bool = true,
        from modes: [ModeCandidate]
    ) -> (index: Int?, hzFellBack: Bool) {
        let matches = modes.enumerated().filter {
            $0.element.width == targetWidth
                && $0.element.height == targetHeight
                && $0.element.usableForDesktopGUI
        }
        guard !matches.isEmpty else { return (nil, false) }

        var pool = matches
        var hzFellBack = false
        if let hz = targetHz, hz > 0 {
            let hzMatches = matches.filter { $0.element.refreshRate == hz }
            if hzMatches.isEmpty {
                hzFellBack = true
            } else {
                pool = hzMatches
            }
        }

        if preferHiDPI {
            let index = pool.max { a, b in
                if a.element.isHiDPI != b.element.isHiDPI {
                    return b.element.isHiDPI   // a < b when b is HiDPI and a is not
                }
                return a.element.refreshRate < b.element.refreshRate
            }?.offset
            return (index, hzFellBack)
        } else {
            let oneX = pool.filter { !$0.element.isHiDPI }
            let subPool = oneX.isEmpty ? pool : oneX
            let index = subPool.max { $0.element.refreshRate < $1.element.refreshRate }?.offset
            return (index, hzFellBack)
        }
    }

    // MARK: - Apply

    /// Switches the display to the best mode matching the requested logical
    /// size (and, when `hz` is set, refresh rate). Persists across reboot
    /// (like System Settings). No sudo required — the console user may
    /// reconfigure their own displays.
    ///
    /// Throws only on a *resolution* miss. An `hz` miss falls back to the best
    /// resolution-matched mode and reports `hzFellBack: true` instead — a
    /// remembered refresh rate must never make a reconnect re-apply fail.
    @discardableResult
    static func apply(
        width: Int,
        height: Int,
        hz: Int? = nil,
        preferHiDPI: Bool = true,
        toDisplayID displayID: CGDirectDisplayID,
        displayName: String
    ) throws -> (mode: CGDisplayMode, hzFellBack: Bool) {
        let modes = allModes(for: displayID)
        let candidates = modes.map {
            ModeCandidate(
                width: $0.width, height: $0.height,
                isHiDPI: $0.pixelWidth > $0.width,
                refreshRate: Int($0.refreshRate.rounded()),
                usableForDesktopGUI: $0.isUsableForDesktopGUI()
            )
        }
        let selection = selectModeIndex(
            targetWidth: width, targetHeight: height, targetHz: hz,
            preferHiDPI: preferHiDPI, from: candidates
        )
        guard let index = selection.index else {
            throw AcuityError.resolutionNotAvailable("\(width)×\(height) on \(displayName)")
        }
        let mode = modes[index]

        // Short-circuit: when the display already sits in the selected mode
        // (the common case at daemon start, since `.permanently` makes the OS
        // itself restore it), skip the WindowServer transaction entirely - a
        // redundant CGComplete can flash the display and blocks the caller.
        if let current = CGDisplayCopyDisplayMode(displayID),
            current.ioDisplayModeID == mode.ioDisplayModeID {
            fputs(
                "[acuity] \(displayName) already at \(width)×\(height)"
                + "\(hz.map { " @ \($0)Hz" } ?? "") - skipping re-apply.\n",
                stderr
            )
            return (current, selection.hzFellBack)
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw AcuityError.setResolutionFailed(displayName, -1)
        }
        let configErr = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        guard configErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw AcuityError.setResolutionFailed(displayName, configErr.rawValue)
        }
        let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeErr == .success else {
            throw AcuityError.setResolutionFailed(displayName, completeErr.rawValue)
        }
        return (mode, selection.hzFellBack)
    }
}
