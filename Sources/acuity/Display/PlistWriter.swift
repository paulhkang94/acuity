import Foundation

/// Reads and writes HiDPI override plist files under
/// `/Library/Displays/Contents/Resources/Overrides`.
///
/// Each override file is named after the display's vendor/product IDs and
/// contains a `scale-resolutions` key that macOS reads on boot to expose
/// additional HiDPI modes.
public struct PlistWriter {

    // MARK: - Paths

    /// Base directory for all display overrides.
    public static let overridesBasePath = URL(
        fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides",
        isDirectory: true
    )

    /// Returns the full file URL for a given vendor/product pair.
    ///
    /// Follows the macOS convention:
    ///   `…/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>`
    public static func overridePath(vendorID: UInt32, productID: UInt32) -> URL {
        overridePath(vendorID: vendorID, productID: productID, baseURL: overridesBasePath)
    }

    /// Testable variant — accepts an arbitrary base URL (e.g. a temp directory).
    public static func overridePath(vendorID: UInt32, productID: UInt32, baseURL: URL) -> URL {
        let vendorDir = "DisplayVendorID-\(String(vendorID, radix: 16, uppercase: false))"
        let productFile = "DisplayProductID-\(String(productID, radix: 16, uppercase: false))"
        return baseURL
            .appendingPathComponent(vendorDir, isDirectory: true)
            .appendingPathComponent(productFile)
    }

    // MARK: - Write

    /// Builds and writes the HiDPI override plist for the given display.
    ///
    /// - Parameters:
    ///   - vendorID:    Display vendor identifier (from EDID).
    ///   - productID:   Display product identifier (from EDID).
    ///   - productName: Human-readable display name stored in the plist.
    ///   - entries:     Logical resolutions to encode as `scale-resolutions`.
    ///
    /// - Throws: File I/O or serialization errors.
    public static func write(
        vendorID: UInt32,
        productID: UInt32,
        productName: String,
        entries: [HiDPIEntry]
    ) throws {
        try write(vendorID: vendorID, productID: productID, productName: productName,
                  entries: entries, baseURL: overridesBasePath)
    }

    /// Testable variant — writes to an arbitrary base URL.
    public static func write(
        vendorID: UInt32,
        productID: UInt32,
        productName: String,
        entries: [HiDPIEntry],
        baseURL: URL
    ) throws {
        let url = overridePath(vendorID: vendorID, productID: productID, baseURL: baseURL)

        // Ensure the vendor directory exists.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Collect all binary variants for every logical resolution.
        let scaleResolutions: [Data] = entries.flatMap { $0.allVariants() }

        let plist: [String: Any] = [
            "DisplayProductID":      Int(productID),
            "DisplayVendorID":       Int(vendorID),
            "DisplayProductName":    productName,
            "scale-resolutions":     scaleResolutions,
            "target-default-ppmm":   10.0699301 as Double,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try data.write(to: url, options: .atomic)
    }

    // MARK: - Remove

    /// Removes the override file (and its vendor directory if now empty).
    ///
    /// - Throws: File I/O errors other than "file not found".
    public static func remove(vendorID: UInt32, productID: UInt32) throws {
        try remove(vendorID: vendorID, productID: productID, baseURL: overridesBasePath)
    }

    public static func remove(vendorID: UInt32, productID: UInt32, baseURL: URL) throws {
        let url = overridePath(vendorID: vendorID, productID: productID, baseURL: baseURL)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)

        // Remove the vendor directory if it is now empty.
        let vendorDir = url.deletingLastPathComponent()
        let remaining = try? fm.contentsOfDirectory(atPath: vendorDir.path)
        if remaining?.isEmpty == true {
            try? fm.removeItem(at: vendorDir)
        }
    }

    // MARK: - Existence check

    /// Returns `true` if an override file already exists for the given IDs.
    public static func exists(vendorID: UInt32, productID: UInt32) -> Bool {
        exists(vendorID: vendorID, productID: productID, baseURL: overridesBasePath)
    }

    public static func exists(vendorID: UInt32, productID: UInt32, baseURL: URL) -> Bool {
        let url = overridePath(vendorID: vendorID, productID: productID, baseURL: baseURL)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
