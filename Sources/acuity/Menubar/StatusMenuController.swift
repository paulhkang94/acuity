import AppKit
import CoreGraphics
import Foundation

/// Owns the NSStatusItem and rebuilds the menu on display change events.
public final class StatusMenuController: NSObject {

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var displays: [DisplayInfo] = []
    private let enumerateDisplays: () -> [DisplayInfo]
    private(set) var isEnablingHiDPI = false

    // MARK: - Lifecycle

    public override convenience init() {
        self.init(enumerateDisplays: DisplayEnumerator.allDisplays)
    }

    init(enumerateDisplays: @escaping () -> [DisplayInfo]) {
        self.enumerateDisplays = enumerateDisplays
        super.init()
    }

    /// Call after NSApplication is running (from main queue).
    public func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "acuity")
        item.button?.image?.isTemplate = true
        statusItem = item
        rebuildMenu()
    }

    // MARK: - Menu

    /// Rebuilds the NSMenu from current DisplayEnumerator.allDisplays().
    public func rebuildMenu() {
        let menu = NSMenu(title: "acuity")
        menu.delegate = self

        populateMenu(menu)

        statusItem?.menu = menu
    }

    // MARK: - Private

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if !isEnablingHiDPI {
            // Re-enumerate on every open: hotplugged displays must appear, and
            // stale per-session CGDirectDisplayIDs from disconnected displays must
            // never linger in representedObjects (a reassigned ID could target the
            // wrong display). The menu already pays O(displays × modes) per open.
            displays = enumerateDisplays()

            let externalDisplays = displays.filter { !$0.isBuiltIn }

            if externalDisplays.isEmpty {
                let noDisplay = NSMenuItem(title: "No external displays", action: nil, keyEquivalent: "")
                noDisplay.isEnabled = false
                menu.addItem(noDisplay)
                menu.addItem(NSMenuItem.separator())
            } else {
                for (index, display) in externalDisplays.enumerated() {
                    let items = DisplayMenuItem.items(for: display, index: index)
                    for item in items {
                        menu.addItem(item)
                    }
                }
            }
        }

        // "Enable HiDPI on All..." action
        let enableAllItem = NSMenuItem(
            title: isEnablingHiDPI ? "Enabling HiDPI…" : "Enable HiDPI on All…",
            action: isEnablingHiDPI ? nil : #selector(enableHiDPIAll(_:)),
            keyEquivalent: ""
        )
        enableAllItem.target = self
        enableAllItem.isEnabled = !isEnablingHiDPI
        menu.addItem(enableAllItem)
        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Acuity",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
    }

    @objc private func enableHiDPIAll(_: NSMenuItem) {
        beginEnableHiDPIAll(
            authorize: authorizeHiDPIAll,
            apply: { inventory in
                Self.applyHiDPILiveToAllExternals(displays: inventory)
            },
            completion: showEnableHiDPIResult
        )
    }

    /// Main owns authorization, topology snapshots, menu state, and completion.
    /// While pending, resolution actions are hidden to prevent overlapping
    /// in-process mode changes and SelectionStore writes.
    func beginEnableHiDPIAll(
        authorize: () -> Bool,
        apply: @escaping ([DisplayInfo]) -> (total: Int, applied: Int),
        completion: @escaping (Int, Int) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard !isEnablingHiDPI else { return }
        isEnablingHiDPI = true
        rebuildMenu()
        guard authorize() else {
            isEnablingHiDPI = false
            rebuildMenu()
            return
        }
        // Snapshot AppKit-derived names on main; mode changes and store I/O
        // use only this value snapshot. Modes may still need a reconnect when
        // an override has just been installed for the first time.
        let inventory = enumerateDisplays()
        DispatchQueue.global(qos: .utility).async {
            let result = apply(inventory)
            DispatchQueue.main.async { [self] in
                isEnablingHiDPI = false
                rebuildMenu()
                completion(result.total, result.applied)
            }
        }
    }

    private func authorizeHiDPIAll() -> Bool {
        // Escalate privileges via the native macOS auth dialog rather than
        // telling the user to open Terminal — the app should own this operation.
        let binaryPath = CommandLine.arguments[0]
        // Escape for AppleScript double-quoted string: backslash → \\, quote → \"
        let escaped = binaryPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\\\"\(escaped)\\\" enable --all\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            showError("Could not initialize privilege escalation.")
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let info = errorInfo {
            // Error code -128 = user cancelled the auth dialog; don't show an error alert.
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return false }
            let message = info[NSAppleScript.errorMessage] as? String ?? "Unknown error (code \(code))"
            showError(message)
            return false
        }

        return true
    }

    private func showEnableHiDPIResult(total: Int, applied: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.messageText = "HiDPI Enabled"
        if total > 0 && applied == total {
            alert.informativeText = "HiDPI is enabled and active on \(applied) display\(applied == 1 ? "" : "s")."
        } else {
            alert.informativeText = "HiDPI override written. The scaled modes activate after you reconnect the display or log out and back in; acuity then applies them automatically."
        }
        alert.runModal()
    }

    /// Applies a HiDPI "looks like" mode live to every external display whose
    /// scaled modes are already present, so "Enable HiDPI on All" takes effect
    /// immediately. Prefers a remembered choice, else the largest HiDPI size
    /// below native. Returns the external-display count and how many applied.
    /// The caller supplies the main-thread inventory; this worker has no UI state.
    static func applyHiDPILiveToAllExternals(
        displays: [DisplayInfo],
        store: SelectionStore = .standard(),
        currentIdentity: (CGDirectDisplayID) -> (vendorID: UInt32, productID: UInt32)? = { displayID in
            guard CGDisplayIsOnline(displayID) != 0 else { return nil }
            return (CGDisplayVendorNumber(displayID), CGDisplayModelNumber(displayID))
        },
        applyMode: (DisplayInfo, Int, Int, Int?) throws -> (refreshRate: Double, hzFellBack: Bool) = { display, width, height, hz in
            let result = try ResolutionController.apply(
                width: width, height: height, hz: hz, preferHiDPI: true,
                toDisplayID: display.displayID, displayName: display.name
            )
            return (result.mode.refreshRate, result.hzFellBack)
        }
    ) -> (total: Int, applied: Int) {
        let externals = displays.filter { $0.isExternal }
        var applied = 0
        for d in externals {
            let target: (width: Int, height: Int, hz: Int?)?
            if let sel = store.selection(vendorID: d.vendorID, productID: d.productID) {
                target = (sel.width, sel.height, sel.hz)
            } else if let largest = ResolutionController.hiDPISizes(for: d.displayID)
                .first(where: { $0.width < d.nativeWidth }) {
                target = (largest.width, largest.height, nil)
            } else {
                target = nil
            }
            guard let t = target else { continue }
            // The snapshot can outlive a disconnect or display-ID reassignment
            // while queued. Recheck online identity immediately before applying.
            guard let identity = currentIdentity(d.displayID),
                  identity.vendorID == d.vendorID,
                  identity.productID == d.productID else { continue }
            do {
                let (refreshRate, hzFellBack) = try applyMode(d, t.width, t.height, t.hz)
                applied += 1
                // Preserve the requested rate across a temporary fallback so
                // reconnect can restore it. Otherwise remember the applied Hz
                // (record() maps a virtual display's 0 Hz to nil).
                if !hzFellBack {
                    try? store.record(
                        vendorID: d.vendorID, productID: d.productID,
                        width: t.width, height: t.height, hz: Int(refreshRate.rounded())
                    )
                }
            } catch {
                // Modes not present yet (needs reboot); leave it for the daemon.
            }
        }
        return (externals.count, applied)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Failed to Enable HiDPI"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate

extension StatusMenuController: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        // populateMenu takes one fresh topology snapshot for every open.
        populateMenu(menu)
    }
}
