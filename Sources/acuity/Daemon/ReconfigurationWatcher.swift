import CoreGraphics
import Foundation

/// Watches for display connection events and automatically re-applies HiDPI overrides.
///
/// Uses `CGDisplayRegisterReconfigurationCallback` to detect when a new external
/// display is connected, then uses public CoreGraphics APIs to select a
/// desktop-usable HiDPI mode if a plist override already exists for that
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

    typealias RememberedApplication = (SelectionStore.Selection, CGDirectDisplayID, String, () -> Bool) throws ->
        (refreshRate: Int, hzFellBack: Bool)

    func applyHiDPIIfOverrideExists(
        target: DisplayWorkTarget,
        canApply: () -> Bool,
        overrideExists: (UInt32, UInt32) -> Bool = PlistWriter.exists,
        applyRemembered: RememberedApplication? = nil,
        fallback: ((CGDirectDisplayID) throws -> Void)? = nil
    ) {
        guard canApply() else { return }
        let displayID = target.displayID
        let vendorID = target.vendorID
        let productID = target.productID
        guard overrideExists(vendorID, productID) else {
            fputs(
                "[acuity] No override plist for \(String(format: "0x%04X", vendorID)):"
                + "\(String(format: "0x%04X", productID)) — skipping.\n",
                stderr
            )
            return
        }

        // Prefer the user's remembered choice over the widest public HiDPI default.
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
                canApply: canApply, applyMode: applyRemembered, fallback: fallback
            )
            return
        }

        fputs(
            "[acuity] Override found - no remembered choice; applying widest public HiDPI for display \(displayID).\n",
            stderr
        )
        applyWidestHiDPIMode(displayID: displayID, canApply: canApply, applyMode: fallback)
    }

    // MARK: - Remembered-selection application

    /// Re-applies a remembered "looks like" size (and refresh rate, when one
    /// was recorded) via the public CoreGraphics path (the same one
    /// `set-resolution` uses). An unavailable remembered Hz never fails the
    /// re-apply — the resolution lands at the best available rate and the
    /// fallback is logged. Falls back to the widest usable public HiDPI mode if the
    /// *resolution* itself can't be applied.
    private func applyRecordedSelection(
        _ sel: SelectionStore.Selection,
        displayID: CGDirectDisplayID,
        displayName: String,
        canApply: () -> Bool,
        applyMode: RememberedApplication? = nil,
        fallback: ((CGDirectDisplayID) throws -> Void)? = nil
    ) {
        guard canApply() else { return }
        do {
            let (appliedHz, hzFellBack) = try (applyMode ?? Self.applyRememberedMode)(
                sel, displayID, displayName, canApply
            )
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
                + "\(error) - falling back to widest public HiDPI.\n",
                stderr
            )
            applyWidestHiDPIMode(displayID: displayID, canApply: canApply, applyMode: fallback)
        }
    }

    private static func applyRememberedMode(
        _ selection: SelectionStore.Selection, displayID: CGDirectDisplayID, displayName: String,
        canApply: () -> Bool
    ) throws -> (refreshRate: Int, hzFellBack: Bool) {
        let (mode, hzFellBack) = try ResolutionController.apply(
            width: selection.width, height: selection.height, hz: selection.hz, preferHiDPI: true,
            toDisplayID: displayID, displayName: displayName, canApply: canApply
        )
        return (Int(mode.refreshRate.rounded()), hzFellBack)
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

    /// Automatic fallback is restricted to desktop-usable public modes.
    private func applyWidestHiDPIMode(
        displayID: CGDirectDisplayID,
        canApply: () -> Bool,
        applyMode: ((CGDirectDisplayID) throws -> Void)? = nil
    ) {
        guard canApply() else { return }
        do {
            if let applyMode {
                try applyMode(displayID)
            } else {
                try ResolutionController.applyWidestHiDPIMode(
                    toDisplayID: displayID, displayName: "Display \(displayID)", canApply: canApply
                )
            }
            fputs("[acuity] Public HiDPI fallback applied for display \(displayID).\n", stderr)
        } catch {
            guard canApply() else { return }
            fputs("[acuity] Public HiDPI fallback unavailable or failed for display \(displayID): \(error).\n", stderr)
        }
    }
}
