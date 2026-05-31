import AppKit
import CoreGraphics
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

        // Probe DDC availability before building the slider.
        // A failed read means the slider would silently do nothing — show it disabled instead.
        let brightnessResult = Result { try ddc.getBrightness(display: display) }
        let ddcAvailable: Bool
        let brightness: Int
        switch brightnessResult {
        case .success(let v):
            acuityDebugLog("DisplayMenuItem: getBrightness=\(v) for display=\(display.displayID) ✓ DDC available")
            ddcAvailable = true
            brightness = v
        case .failure(let e):
            acuityDebugLog("DisplayMenuItem: getBrightness FAILED for display=\(display.displayID) — \(e) → slider disabled")
            ddcAvailable = false
            brightness = 50
        }
        let sliderView = BrightnessSliderView(ddc: ddc, display: display, currentBrightness: brightness, ddcAvailable: ddcAvailable)
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

        // Resolution submenu — live HiDPI switching + soft comparison.
        items.append(resolutionItem(for: display))

        // Separator after each display section
        items.append(NSMenuItem.separator())

        return items
    }

    // MARK: - Resolution submenu

    /// Builds the "Resolution" submenu: native, the HiDPI ("sharp") sizes, and
    /// a few 1× ("soft") sizes so the HiDPI difference is visible at a matching
    /// scale. The active mode is checkmarked. Selecting an item switches live.
    private static func resolutionItem(for display: DisplayInfo) -> NSMenuItem {
        let current = ResolutionController.currentMode(for: display.displayID)
        let curW = current?.width ?? 0
        let curH = current?.height ?? 0
        let curHiDPI = (current?.pixelWidth ?? 0) > (current?.width ?? 0)

        let submenu = NSMenu(title: "Resolution")

        func add(_ title: String, width: Int, height: Int, hidpi: Bool, checked: Bool) {
            let item = NSMenuItem(title: title, action: #selector(ResolutionTarget.selectResolution(_:)), keyEquivalent: "")
            item.target = ResolutionTarget.shared
            item.representedObject = ResolutionSelection(displayID: display.displayID, displayName: display.name, width: width, height: height, preferHiDPI: hidpi)
            item.state = checked ? .on : .off
            submenu.addItem(item)
        }

        // Native (1×) — full resolution, smallest UI.
        add("\(display.nativeWidth) × \(display.nativeHeight)  ·  100% (native)",
            width: display.nativeWidth, height: display.nativeHeight, hidpi: true,
            checked: curW == display.nativeWidth && curH == display.nativeHeight)

        let hiDPI = ResolutionController.hiDPISizes(for: display.displayID)
            .filter { $0.width < display.nativeWidth }  // native already shown above
        if !hiDPI.isEmpty {
            let header = NSMenuItem(title: "HiDPI — sharp", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for m in hiDPI {
                let zoom = m.zoomPercent(nativeWidth: display.nativeWidth)
                add("\(m.width) × \(m.height)  ·  \(zoom)%",
                    width: m.width, height: m.height, hidpi: true,
                    checked: curHiDPI && curW == m.width && curH == m.height)
            }
        }

        // Soft (1×) comparison — only sizes that also exist as HiDPI, top few.
        let hiDPIKeys = Set(hiDPI.map { "\($0.width)x\($0.height)" })
        let soft = ResolutionController.oneXSizes(for: display.displayID)
            .filter { hiDPIKeys.contains("\($0.width)x\($0.height)") }
            .prefix(3)
        if !soft.isEmpty {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: "No HiDPI — soft (compare)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for m in soft {
                let zoom = m.zoomPercent(nativeWidth: display.nativeWidth)
                add("\(m.width) × \(m.height)  ·  \(zoom)% (soft)",
                    width: m.width, height: m.height, hidpi: false,
                    checked: !curHiDPI && curW == m.width && curH == m.height)
            }
        }

        let title: String
        if curHiDPI {
            title = "Resolution: \(curW)×\(curH) HiDPI"
        } else {
            title = "Resolution: \(curW)×\(curH)"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
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

// MARK: - Resolution selection

/// Bundles the parameters needed to switch a display's resolution.
private struct ResolutionSelection {
    let displayID: CGDirectDisplayID
    let displayName: String
    let width: Int
    let height: Int
    let preferHiDPI: Bool
}

/// NSObject target for resolution menu item actions. Applies the mode live via
/// `ResolutionController` (CGDisplaySetDisplayMode — no reboot, no sudo).
private final class ResolutionTarget: NSObject {
    static let shared = ResolutionTarget()

    @objc func selectResolution(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? ResolutionSelection else { return }
        do {
            try ResolutionController.apply(
                width: sel.width, height: sel.height, preferHiDPI: sel.preferHiDPI,
                toDisplayID: sel.displayID, displayName: sel.displayName
            )
        } catch {
            fputs("[acuity] ResolutionTarget: \(error.localizedDescription)\n", stderr)
        }
    }
}
