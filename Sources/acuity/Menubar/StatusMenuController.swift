import AppKit
import Foundation

/// Owns the NSStatusItem and rebuilds the menu on display change events.
public final class StatusMenuController: NSObject {

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var displays: [DisplayInfo] = []

    // MARK: - Lifecycle

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
        displays = DisplayEnumerator.allDisplays()

        let menu = NSMenu(title: "acuity")
        menu.delegate = self

        populateMenu(menu)

        statusItem?.menu = menu
    }

    // MARK: - Private

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

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

        // "Enable HiDPI on All..." action
        let enableAllItem = NSMenuItem(
            title: "Enable HiDPI on All…",
            action: #selector(enableHiDPIAll(_:)),
            keyEquivalent: ""
        )
        enableAllItem.target = self
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
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let info = errorInfo {
            // Error code -128 = user cancelled the auth dialog; don't show an error alert.
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return }
            let message = info[NSAppleScript.errorMessage] as? String ?? "Unknown error (code \(code))"
            showError(message)
            return
        }

        // The override is written. If the scaled modes are already live (the
        // common case once a display has been enabled before), apply HiDPI now
        // so the change is visible immediately instead of telling the user to
        // reboot. Fall back to the reboot message only when the modes aren't
        // present yet (a first-ever enable on a fresh display).
        let (total, applied) = applyHiDPILiveToAllExternals()
        rebuildMenu()

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
    private func applyHiDPILiveToAllExternals() -> (total: Int, applied: Int) {
        let externals = DisplayEnumerator.allDisplays().filter { $0.isExternal }
        let store = SelectionStore.standard()
        var applied = 0
        for d in externals {
            let target: (width: Int, height: Int)?
            if let sel = store.selection(vendorID: d.vendorID, productID: d.productID) {
                target = (sel.width, sel.height)
            } else if let largest = ResolutionController.hiDPISizes(for: d.displayID)
                .first(where: { $0.width < d.nativeWidth }) {
                target = (largest.width, largest.height)
            } else {
                target = nil
            }
            guard let t = target else { continue }
            do {
                _ = try ResolutionController.apply(
                    width: t.width, height: t.height, preferHiDPI: true,
                    toDisplayID: d.displayID, displayName: d.name
                )
                applied += 1
                try? store.record(vendorID: d.vendorID, productID: d.productID, width: t.width, height: t.height)
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
        populateMenu(menu)
    }
}
