import CoreGraphics
import Foundation

/// Watches for display connection events and automatically re-applies HiDPI overrides.
///
/// Uses `CGDisplayRegisterReconfigurationCallback` to detect when a new external
/// display is connected, then invokes CGS private APIs (the same ones displayplacer
/// uses) to switch into the HiDPI mode if a plist override already exists for that
/// display's vendor/product ID pair.
public final class ReconfigurationWatcher {

    // MARK: - State

    private var isWatching = false
    private let selectionStore: SelectionStore

    // MARK: - Lifecycle

    /// - Parameter selectionStore: remembers the user's chosen resolution per
    ///   display, so reconnect/boot re-applies THAT size rather than the
    ///   largest available HiDPI mode.
    public init(selectionStore: SelectionStore) {
        self.selectionStore = selectionStore
    }

    /// Registers the display reconfiguration callback.
    ///
    /// Safe to call multiple times — subsequent calls are no-ops.
    public func startWatching() {
        guard !isWatching else { return }
        isWatching = true

        CGDisplayRegisterReconfigurationCallback(
            { displayID, flags, userInfo in
                guard flags.contains(.addFlag) else { return }
                let watcher = Unmanaged<ReconfigurationWatcher>
                    .fromOpaque(userInfo!)
                    .takeUnretainedValue()
                watcher.handleDisplayAdded(displayID: displayID)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        fputs("[acuity] ReconfigurationWatcher started.\n", stderr)

        // Cold-boot path: displays already attached at login never fire the
        // .addFlag callback, so re-apply each remembered choice now.
        applyRecordedSelectionsToConnectedDisplays()
    }

    /// Removes the display reconfiguration callback.
    public func stopWatching() {
        guard isWatching else { return }
        isWatching = false

        CGDisplayRemoveReconfigurationCallback(
            { _, _, _ in },
            Unmanaged.passUnretained(self).toOpaque()
        )

        fputs("[acuity] ReconfigurationWatcher stopped.\n", stderr)
    }

    // MARK: - Display-add handler

    private func handleDisplayAdded(displayID: CGDirectDisplayID) {
        let vendorID  = UInt32(CGDisplayVendorNumber(displayID))
        let productID = UInt32(CGDisplayModelNumber(displayID))

        fputs(
            "[acuity] Display connected: \(String(format: "0x%04X", vendorID)):"
            + "\(String(format: "0x%04X", productID)) — waiting 2s for stabilization.\n",
            stderr
        )

        // Give the display 2 seconds to finish enumeration before poking CGS.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.applyHiDPIIfOverrideExists(displayID: displayID, vendorID: vendorID, productID: productID)
        }
    }

    // MARK: - HiDPI application

    private func applyHiDPIIfOverrideExists(
        displayID: CGDirectDisplayID,
        vendorID: UInt32,
        productID: UInt32
    ) {
        let plistURL = PlistWriter.overridePath(vendorID: vendorID, productID: productID)

        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            fputs(
                "[acuity] No override plist for \(String(format: "0x%04X", vendorID)):"
                + "\(String(format: "0x%04X", productID)) — skipping.\n",
                stderr
            )
            return
        }

        // Prefer the user's remembered choice over the largest-HiDPI default.
        if let sel = selectionStore.selection(vendorID: vendorID, productID: productID) {
            fputs(
                "[acuity] Override found — applying remembered \(sel.width)×\(sel.height) for display \(displayID).\n",
                stderr
            )
            applyRecordedSelection(
                sel,
                displayID: displayID,
                displayName: String(format: "Display %04x:%04x", vendorID, productID)
            )
            return
        }

        fputs(
            "[acuity] Override found — no remembered choice; applying largest HiDPI for display \(displayID).\n",
            stderr
        )
        applyHiDPIMode(displayID: displayID)
    }

    // MARK: - Remembered-selection application

    /// Re-applies a remembered "looks like" size via the public CoreGraphics
    /// path (the same one `set-resolution` uses). Falls back to the largest
    /// HiDPI mode if that specific size can't be applied.
    private func applyRecordedSelection(
        _ sel: SelectionStore.Selection,
        displayID: CGDirectDisplayID,
        displayName: String
    ) {
        do {
            _ = try ResolutionController.apply(
                width: sel.width, height: sel.height, preferHiDPI: true,
                toDisplayID: displayID, displayName: displayName
            )
            fputs("[acuity] Re-applied remembered \(sel.width)×\(sel.height) for \(displayName).\n", stderr)
        } catch {
            fputs(
                "[acuity] Could not apply remembered \(sel.width)×\(sel.height) for \(displayName): "
                + "\(error) — falling back to largest HiDPI.\n",
                stderr
            )
            applyHiDPIMode(displayID: displayID)
        }
    }

    /// Cold-boot path: displays already attached at login don't fire the
    /// `.addFlag` callback, so re-apply each remembered choice at daemon start.
    private func applyRecordedSelectionsToConnectedDisplays() {
        for display in DisplayEnumerator.allDisplays() where !display.isBuiltIn {
            guard let sel = selectionStore.selection(
                vendorID: display.vendorID, productID: display.productID
            ) else { continue }
            applyRecordedSelection(sel, displayID: display.displayID, displayName: display.name)
        }
    }

    // MARK: - HiDPI application

    /// Applies HiDPI mode using CGS private APIs resolved via dlsym.
    ///
    /// The APIs used here are identical to those used by displayplacer:
    ///   - `CGSGetNumberOfDisplayModes`
    ///   - `CGSGetDisplayModeDescriptionOfLength`
    ///   - `CGSConfigureDisplayMode`
    ///
    /// These are private but do not require a special entitlement; any process
    /// running as the console user can call them.
    private func applyHiDPIMode(displayID: CGDirectDisplayID) {
        // Resolve function pointers via dlsym so the binary has no hard link
        // against the private SPI symbols.
        typealias GetNumberOfModesFn = @convention(c) (CGDirectDisplayID) -> Int32
        typealias GetModeDescFn      = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError
        typealias ConfigureModeFn    = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

        guard
            let handle             = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
            let numModesPtr        = dlsym(handle, "CGSGetNumberOfDisplayModes"),
            let getModeDescPtr     = dlsym(handle, "CGSGetDisplayModeDescriptionOfLength"),
            let configureModePtr   = dlsym(handle, "CGSConfigureDisplayMode")
        else {
            fputs("[acuity] Failed to resolve CGS private APIs via dlsym.\n", stderr)
            return
        }

        let getNumberOfModes = unsafeBitCast(numModesPtr,      to: GetNumberOfModesFn.self)
        let getModeDesc      = unsafeBitCast(getModeDescPtr,   to: GetModeDescFn.self)
        let configureMode    = unsafeBitCast(configureModePtr, to: ConfigureModeFn.self)

        let count = getNumberOfModes(displayID)
        guard count > 0 else {
            fputs("[acuity] No display modes returned for display \(displayID).\n", stderr)
            return
        }

        // CGSDisplayModeDescription layout (opaque, 256 bytes).
        // Byte offsets verified against open-source displayplacer implementation.
        let descSize = 256
        var modeBuffer = [UInt8](repeating: 0, count: descSize)

        var bestModeIndex: Int32 = -1
        var bestWidth:     Int32 = 0

        for index in 0..<count {
            let result = modeBuffer.withUnsafeMutableBytes { ptr in
                getModeDesc(displayID, index, ptr.baseAddress!, Int32(descSize))
            }
            guard result == .success else { continue }

            // Width is at offset 8, height at offset 12 (Int32, little-endian).
            let width  = modeBuffer.withUnsafeBytes { $0.load(fromByteOffset: 8,  as: Int32.self) }
            let flags  = modeBuffer.withUnsafeBytes { $0.load(fromByteOffset: 48, as: UInt32.self) }

            // Bit 2 of the flags field indicates a HiDPI / "retina" mode.
            let isHiDPI = (flags & 0x4) != 0

            if isHiDPI && width > bestWidth {
                bestWidth     = width
                bestModeIndex = index
            }
        }

        guard bestModeIndex >= 0 else {
            fputs("[acuity] No HiDPI modes found for display \(displayID).\n", stderr)
            return
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success else {
            fputs("[acuity] CGBeginDisplayConfiguration failed.\n", stderr)
            return
        }

        let setResult = configureMode(configRef, displayID, bestModeIndex)
        guard setResult == .success else {
            CGCancelDisplayConfiguration(configRef)
            fputs("[acuity] CGSConfigureDisplayMode failed: \(setResult.rawValue).\n", stderr)
            return
        }

        let applyResult = CGCompleteDisplayConfiguration(configRef, .permanently)
        if applyResult == .success {
            fputs(
                "[acuity] HiDPI mode (index \(bestModeIndex)) applied successfully "
                + "for display \(displayID).\n",
                stderr
            )
        } else {
            fputs("[acuity] CGCompleteDisplayConfiguration failed: \(applyResult.rawValue).\n", stderr)
        }
    }
}
