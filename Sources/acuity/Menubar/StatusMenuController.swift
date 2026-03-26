import AppKit
import Foundation

/// Owns the NSStatusItem and rebuilds the menu on display change events.
/// Injected with DDCControlling for testability.
public final class StatusMenuController: NSObject {

    // MARK: - State

    private var statusItem: NSStatusItem?
    private let ddc: DDCControlling
    private var displays: [DisplayInfo] = []

    // MARK: - Init

    public init(ddc: DDCControlling) {
        self.ddc = ddc
        super.init()
    }

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
                let items = DisplayMenuItem.items(for: display, ddc: ddc, index: index)
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
            // Error code -128 = user cancelled the auth dialog — don't show an error alert
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return }
            let message = info[NSAppleScript.errorMessage] as? String ?? "Unknown error (code \(code))"
            showError(message)
        } else {
            let alert = NSAlert()
            alert.messageText = "HiDPI Enabled"
            alert.informativeText = "HiDPI has been enabled on all displays. Reconnect your displays or log out and back in to apply."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
