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
        // Show a brief alert if not running as root
        let alert = NSAlert()
        alert.messageText = "Enable HiDPI on All Displays"
        alert.informativeText = "Run the following command in Terminal:\n\nsudo acuity enable --all"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate

extension StatusMenuController: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
