import AppKit
import Foundation

/// Factory that builds the per-display section items for the status menu.
/// Returns an array of NSMenuItems: header, brightness row, input submenu, separator.
public struct DisplayMenuItem {

    // MARK: - Factory

    /// Builds the menu items for one display.
    public static func items(
        for display: DisplayInfo,
        ddc: DDCControlling,
        index: Int
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // Header: "Display N: <name>  [HiDPI ✓ / ✗]"
        let hiDPIBadge = isHiDPIEnabled(for: display) ? "✓" : "✗"
        let headerItem = NSMenuItem(
            title: "Display \(index + 1): \(display.name)  HiDPI \(hiDPIBadge)",
            action: nil,
            keyEquivalent: ""
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
        ]
        headerItem.attributedTitle = NSAttributedString(string: headerItem.title, attributes: attrs)
        headerItem.isEnabled = false
        items.append(headerItem)

        // Brightness slider row — log DDC availability so failures aren't silent
        let brightnessResult = Result { try ddc.getBrightness(display: display) }
        switch brightnessResult {
        case .success(let v):
            print("PHK DisplayMenuItem: getBrightness=\(v) for display=\(display.displayID) ✓")
        case .failure(let e):
            print("PHK DisplayMenuItem: getBrightness FAILED for display=\(display.displayID) — \(e)")
        }
        let brightness = (try? brightnessResult.get()) ?? 50
        let sliderView = BrightnessSliderView(ddc: ddc, display: display, currentBrightness: brightness)
        let brightnessItem = NSMenuItem()
        brightnessItem.view = sliderView
        items.append(brightnessItem)

        // Input source submenu
        let currentInput = currentInputSource(for: display, ddc: ddc)
        let inputItem = NSMenuItem(
            title: "Input: \(currentInput?.description ?? "Unknown")",
            action: nil,
            keyEquivalent: ""
        )
        let inputSubmenu = NSMenu(title: "Input")
        for source in InputSource.allCases {
            let sourceItem = NSMenuItem(
                title: source.description,
                action: #selector(InputSourceTarget.selectInput(_:)),
                keyEquivalent: ""
            )
            sourceItem.representedObject = InputSourceSelection(source: source, display: display, ddc: ddc)
            sourceItem.target = InputSourceTarget.shared
            inputSubmenu.addItem(sourceItem)
        }
        inputItem.submenu = inputSubmenu
        items.append(inputItem)

        // Separator after each display section
        items.append(NSMenuItem.separator())

        return items
    }

    // MARK: - Helpers

    private static func isHiDPIEnabled(for display: DisplayInfo) -> Bool {
        let path = PlistWriter.overridePath(vendorID: display.vendorID, productID: display.productID)
        return FileManager.default.fileExists(atPath: path.path)
    }

    private static func currentInputSource(for display: DisplayInfo, ddc: DDCControlling) -> InputSource? {
        // DDC read for input source is optional — failure is non-fatal
        nil
    }
}

// MARK: - InputSource CaseIterable

extension InputSource: CaseIterable {
    public static var allCases: [InputSource] {
        [.vga1, .displayPort1, .displayPort2, .hdmi1, .hdmi2, .usbC]
    }
}

// MARK: - InputSourceSelection helper

/// Bundles the parameters needed to apply an input source change.
private struct InputSourceSelection {
    let source: InputSource
    let display: DisplayInfo
    let ddc: DDCControlling
}

// MARK: - InputSourceTarget

/// NSObject target for input-source menu item actions.
private final class InputSourceTarget: NSObject {
    static let shared = InputSourceTarget()

    @objc func selectInput(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? InputSourceSelection else { return }
        do {
            try selection.ddc.setInput(selection.source, display: selection.display)
        } catch {
            fputs("[acuity] InputSourceTarget: DDC error: \(error)\n", stderr)
        }
    }
}
