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
    private let registrationLock = NSLock()
    private let selectionStore: SelectionStore
    private let work: DisplayWorkScheduler
    private let enumerateDisplays: () -> [DisplayInfo]
    private let onMain: (@escaping () -> Void) -> Void
    private let registerCallback: (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError
    private let removeCallback: (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError

    /// Called on the main queue after any display topology change (add or
    /// remove), so UI owners (the menubar) can refresh their display lists.
    public var onDisplayChange: (() -> Void)?

    // MARK: - Lifecycle

    /// - Parameter selectionStore: remembers the user's chosen resolution per
    ///   display, so reconnect/boot re-applies THAT size rather than the
    ///   largest available HiDPI mode.
    public convenience init(selectionStore: SelectionStore) {
        self.init(selectionStore: selectionStore, work: DisplayWorkScheduler())
    }

    init(
        selectionStore: SelectionStore,
        work: DisplayWorkScheduler,
        enumerateDisplays: @escaping () -> [DisplayInfo] = DisplayEnumerator.allDisplays,
        onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        registerCallback: @escaping (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError = {
            CGDisplayRegisterReconfigurationCallback($0, $1)
        },
        removeCallback: @escaping (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError = {
            CGDisplayRemoveReconfigurationCallback($0, $1)
        }
    ) {
        self.selectionStore = selectionStore
        self.work = work
        self.enumerateDisplays = enumerateDisplays
        self.onMain = onMain
        self.registerCallback = registerCallback
        self.removeCallback = removeCallback
    }

    /// The single C callback registered with CoreGraphics. Stored once so
    /// `stopWatching` can pass the IDENTICAL function pointer to the removal
    /// call — distinct closure literals lower to distinct C thunks, and CG
    /// matches removals on the (callback, userInfo) pair, so passing a fresh
    /// literal makes removal a silent no-op.
    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
        let watcher = Unmanaged<ReconfigurationWatcher>
            .fromOpaque(userInfo!)
            .takeUnretainedValue()
        watcher.handleDisplayChange(displayID: displayID, flags: flags)
    }

    /// Registers the display reconfiguration callback.
    ///
    /// Safe to call multiple times — subsequent calls are no-ops.
    public func startWatching() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !isWatching else { return }
        isWatching = true

        let err = registerCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err != .success {
            fputs("[acuity] CGDisplayRegisterReconfigurationCallback failed: \(err.rawValue).\n", stderr)
            isWatching = false
            return
        }

        fputs("[acuity] ReconfigurationWatcher started.\n", stderr)

        let session = work.start()
        // NSScreen-derived inventory belongs on main. Each remembered display
        // becomes its own cancellable utility-queue work unit afterward.
        onMain { [weak self] in
            guard let self, work.isCurrent(session) else { return }
            scheduleRecordedSelections(session: session)
        }
    }

    /// Removes the display reconfiguration callback. Must pass the same
    /// (callback, userInfo) pair used at registration or CG leaves the old
    /// registration live — with `passUnretained` userInfo that would turn the
    /// next hotplug after deallocation into a use-after-free.
    public func stopWatching() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard isWatching else { return }
        work.stop()

        let err = removeCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if err != .success {
            fputs("[acuity] CGDisplayRemoveReconfigurationCallback failed: \(err.rawValue).\n", stderr)
            return
        }

        isWatching = false
        fputs("[acuity] ReconfigurationWatcher stopped.\n", stderr)
    }

    // MARK: - Display-add handler

    /// Callback entry may arrive off main; scheduler bookkeeping is synchronized.
    func handleDisplayChange(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard let session = work.currentSession else { return }
        if flags.contains(.removeFlag) {
            work.cancel(displayID: displayID, session: session)
        }
        if flags.contains(.addFlag), let target = work.currentTarget(for: displayID) {
            fputs("[acuity] Display \(displayID) connected - waiting 2s for stabilization.\n", stderr)
            work.enqueue(target, session: session) { [weak self] canApply in
                self?.applyHiDPIIfOverrideExists(target: target, canApply: canApply)
            }
        }
        onMain { [weak self] in
            guard let self, work.isCurrent(session) else { return }
            onDisplayChange?()
        }
    }

    // MARK: - HiDPI application

    private func applyHiDPIIfOverrideExists(
        target: DisplayWorkTarget,
        canApply: () -> Bool
    ) {
        guard canApply() else { return }
        let displayID = target.displayID
        let vendorID = target.vendorID
        let productID = target.productID
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
            let hzSuffix = sel.hz.map { " @ \($0)Hz" } ?? ""
            fputs(
                "[acuity] Override found — applying remembered \(sel.width)×\(sel.height)\(hzSuffix) for display \(displayID).\n",
                stderr
            )
            applyRecordedSelection(
                sel,
                displayID: displayID,
                displayName: String(format: "Display %04x:%04x", vendorID, productID),
                canApply: canApply
            )
            return
        }

        fputs(
            "[acuity] Override found — no remembered choice; applying largest HiDPI for display \(displayID).\n",
            stderr
        )
        applyHiDPIMode(displayID: displayID, canApply: canApply)
    }

    // MARK: - Remembered-selection application

    /// Re-applies a remembered "looks like" size (and refresh rate, when one
    /// was recorded) via the public CoreGraphics path (the same one
    /// `set-resolution` uses). An unavailable remembered Hz never fails the
    /// re-apply — the resolution lands at the best available rate and the
    /// fallback is logged. Falls back to the largest HiDPI mode only if the
    /// *resolution* itself can't be applied.
    private func applyRecordedSelection(
        _ sel: SelectionStore.Selection,
        displayID: CGDirectDisplayID,
        displayName: String,
        canApply: () -> Bool
    ) {
        guard canApply() else { return }
        do {
            let (mode, hzFellBack) = try ResolutionController.apply(
                width: sel.width, height: sel.height, hz: sel.hz, preferHiDPI: true,
                toDisplayID: displayID, displayName: displayName
            )
            let appliedHz = Int(mode.refreshRate.rounded())
            if hzFellBack, let rememberedHz = sel.hz {
                fputs(
                    "[acuity] remembered \(rememberedHz)Hz unavailable — applied "
                    + "\(sel.width)×\(sel.height) at \(appliedHz)Hz for \(displayName).\n",
                    stderr
                )
            } else {
                fputs(
                    "[acuity] Re-applied remembered \(sel.width)×\(sel.height)"
                    + "\(sel.hz.map { " @ \($0)Hz" } ?? "") for \(displayName).\n",
                    stderr
                )
            }
        } catch {
            guard canApply() else { return }
            fputs(
                "[acuity] Could not apply remembered \(sel.width)×\(sel.height) for \(displayName): "
                + "\(error) — falling back to largest HiDPI.\n",
                stderr
            )
            applyHiDPIMode(displayID: displayID, canApply: canApply)
        }
    }

    /// Called on main so AppKit-derived names never move to a utility queue.
    private func scheduleRecordedSelections(session: UUID) {
        for display in enumerateDisplays() where !display.isBuiltIn {
            let target = DisplayWorkTarget(
                displayID: display.displayID, vendorID: display.vendorID, productID: display.productID
            )
            // A concurrent add event owns its two-second stabilization delay.
            work.enqueue(target, after: 0, session: session, replacing: false) { [weak self] canApply in
                guard let self, canApply(), let sel = selectionStore.selection(
                    vendorID: display.vendorID, productID: display.productID
                ) else { return }
                applyRecordedSelection(
                    sel, displayID: display.displayID, displayName: display.name, canApply: canApply
                )
            }
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
    private func applyHiDPIMode(displayID: CGDirectDisplayID, canApply: () -> Bool) {
        guard canApply() else { return }
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

        guard canApply() else { return }
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
