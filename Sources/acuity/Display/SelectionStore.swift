import Foundation

/// Remembers the user's chosen "looks like" resolution per display, so the
/// daemon can re-apply THAT choice on reconnect or at login — instead of
/// defaulting to the largest HiDPI mode. Persisted as JSON under Application
/// Support so it survives reboots.
///
/// Keyed by the display's EDID vendor:product pair (stable across reconnects
/// and reboots), never the CoreGraphics display ID (which is per-session).
///
/// Side-effecting (writes a file), so it is injected into its consumers
/// (`ReconfigurationWatcher`, the commands) rather than instantiated internally —
/// tests pass a temp-file-backed store.
public final class SelectionStore {

    /// One remembered logical ("looks like") size for a display.
    public struct Selection: Codable, Equatable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    private let fileURL: URL

    /// Production store at
    /// `~/Library/Application Support/acuity/selected-resolutions.json`.
    ///
    /// Both `set-resolution` (run as the console user) and the daemon (a
    /// LaunchAgent in the user's GUI session) resolve this to the same path.
    public static func standard() -> SelectionStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("acuity", isDirectory: true)
        return SelectionStore(fileURL: dir.appendingPathComponent("selected-resolutions.json"))
    }

    /// Designated initializer. Tests inject a temp-directory file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Stable key for a display: zero-padded lowercase hex `"vendor:product"`.
    public static func key(vendorID: UInt32, productID: UInt32) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// Records (upserts) the chosen logical size for a display.
    public func record(vendorID: UInt32, productID: UInt32, width: Int, height: Int) throws {
        var all = readAll()
        all[Self.key(vendorID: vendorID, productID: productID)] = Selection(width: width, height: height)
        try writeAll(all)
    }

    /// Returns the recorded selection for a display, or `nil` if none.
    public func selection(vendorID: UInt32, productID: UInt32) -> Selection? {
        readAll()[Self.key(vendorID: vendorID, productID: productID)]
    }

    // MARK: - Persistence

    /// Reads the full map. Returns empty on a missing or corrupt file — a bad
    /// store must never crash the daemon; it just means "no remembered choice".
    public func readAll() -> [String: Selection] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Selection].self, from: data)
        else { return [:] }
        return decoded
    }

    private func writeAll(_ all: [String: Selection]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)
        try data.write(to: fileURL, options: .atomic)
    }
}
