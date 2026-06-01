import Foundation

/// Scaling preset to apply when generating HiDPI resolution candidates.
public enum ScalingPreset {
    /// Only the exact 2× scaled resolution (half of native on each axis).
    case twoX
    /// Only the 1.5× scaled resolution.
    case onePointFiveX
    /// Only the 1.33× scaled resolution.
    case onePointThreeX
    /// All common scaled resolutions for the native size.
    case all
    /// A single explicit logical resolution.
    case custom(width: Int, height: Int)
}

/// Generates `HiDPIEntry` sets for well-known native display resolutions.
public struct DisplayPresets {

    // MARK: - Public API

    /// Returns the appropriate `HiDPIEntry` array for the given native resolution and preset.
    ///
    /// Falls back to a computed set when the native resolution is not in the known-preset table.
    public static func forNativeResolution(
        width: Int,
        height: Int,
        preset: ScalingPreset
    ) -> [HiDPIEntry] {
        switch preset {
        case .twoX:
            return [HiDPIEntry(logicalWidth: width / 2, logicalHeight: height / 2)]

        case .onePointFiveX:
            let w = Int((Double(width) / 1.5).rounded())
            let h = Int((Double(height) / 1.5).rounded())
            return [HiDPIEntry(logicalWidth: w, logicalHeight: h)]

        case .onePointThreeX:
            let w = Int((Double(width) / 1.3).rounded())
            let h = Int((Double(height) / 1.3).rounded())
            return [HiDPIEntry(logicalWidth: w, logicalHeight: h)]

        case .custom(let w, let h):
            return [HiDPIEntry(logicalWidth: w, logicalHeight: h)]

        case .all:
            return allPresetsFor(width: width, height: height)
        }
    }

    // MARK: - Known-resolution tables

    /// Full resolution ladder for common native resolutions.
    ///
    /// Sources: https://en.wikipedia.org/wiki/Graphics_display_resolution
    private static let knownPresets: [String: [HiDPIEntry]] = [
        // QHD 2560×1440
        key(2560, 1440): entries([
            (2560, 1440), (2048, 1152), (1920, 1080),
            (1680, 945),  (1600, 900),  (1440, 810),
            (1280, 720),  (1024, 576),  (960, 540)
        ]),
        // 4K UHD 3840×2160
        key(3840, 2160): entries([
            (3840, 2160), (3200, 1800), (2560, 1440),
            (1920, 1080), (1600, 900),  (1280, 720)
        ]),
        // Apple 2560×1600 (16:10)
        key(2560, 1600): entries([
            (2560, 1600), (1920, 1200), (1680, 1050),
            (1280, 800),  (1024, 640)
        ]),
        // Ultrawide 3440×1440
        key(3440, 1440): entries([
            (3440, 1440), (2560, 1080), (1720, 720),
            (1280, 540)
        ]),
        // FHD 1920×1080
        key(1920, 1080): entries([
            (1920, 1080), (1600, 900), (1280, 720),
            (1024, 576),  (960, 540)
        ]),
    ]

    // MARK: - Private helpers

    private static func allPresetsFor(width: Int, height: Int) -> [HiDPIEntry] {
        if let known = knownPresets[key(width, height)] {
            return known
        }
        // Fallback: compute a descending ladder from native down to ~1/4 size.
        return computedLadder(width: width, height: height)
    }

    /// Generates a stepped resolution ladder for arbitrary native sizes.
    private static func computedLadder(width: Int, height: Int) -> [HiDPIEntry] {
        let steps: [Double] = [1.0, 0.8, 0.75, 0.667, 0.5, 0.375, 0.25]
        return steps.compactMap { scale -> HiDPIEntry? in
            let w = Int((Double(width) * scale).rounded())
            let h = Int((Double(height) * scale).rounded())
            guard w >= 640, h >= 400 else { return nil }
            return HiDPIEntry(logicalWidth: w, logicalHeight: h)
        }
    }

    private static func key(_ w: Int, _ h: Int) -> String { "\(w)x\(h)" }

    private static func entries(_ pairs: [(Int, Int)]) -> [HiDPIEntry] {
        pairs.map { HiDPIEntry(logicalWidth: $0.0, logicalHeight: $0.1) }
    }
}
