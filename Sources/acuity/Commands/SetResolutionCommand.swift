import ArgumentParser
import CoreGraphics
import Foundation

struct SetResolutionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-resolution",
        abstract: "Switch a display to a HiDPI scaled resolution (the 'looks like' size)."
    )

    @Option(name: .long, help: "Target a specific display by vendor:product ID (hex, e.g. 0x10ac:0x41da).")
    var display: String?

    @Flag(name: .long, help: "Apply to all connected external displays.")
    var all: Bool = false

    @Option(name: .long, help: "Logical ('looks like') width to switch to.")
    var width: Int?

    @Option(name: .long, help: "Logical ('looks like') height to switch to.")
    var height: Int?

    @Flag(name: .long, help: "Use the 1× (non-HiDPI) variant — softer; shows what you get without acuity.")
    var noHidpi: Bool = false

    @Flag(name: .long, help: "List the available HiDPI 'looks like' sizes instead of switching.")
    var list: Bool = false

    func run() throws {
        let targets: [DisplayInfo]
        if all {
            targets = DisplayEnumerator.allDisplays().filter { $0.isExternal }
            guard !targets.isEmpty else { throw AcuityError.noExternalDisplays }
        } else {
            targets = [try resolveTargetDisplay(display)]
        }

        if list {
            for info in targets { printAvailableModes(info) }
            return
        }

        guard let width, let height else {
            throw AcuityError.invalidDisplayArgument("set-resolution needs --width and --height (or --list)")
        }

        // Remember each choice so the daemon re-applies THIS size on reboot /
        // reconnect, rather than defaulting to the largest HiDPI mode.
        let store = SelectionStore.standard()

        for info in targets {
            let mode = try ResolutionController.apply(
                width: width, height: height, preferHiDPI: !noHidpi,
                toDisplayID: info.displayID, displayName: info.name
            )
            let kind = mode.pixelWidth > mode.width ? "HiDPI, sharp" : "1×, soft"
            print("✓ \(info.name) → looks like \(mode.width)×\(mode.height) "
                + "(renders \(mode.pixelWidth)×\(mode.pixelHeight) @\(Int(mode.refreshRate.rounded()))Hz · \(kind))")

            // Only remember HiDPI selections — a 1× (--no-hidpi) pick is a
            // one-off comparison, not a preference worth restoring on boot.
            if !noHidpi {
                do {
                    try store.record(vendorID: info.vendorID, productID: info.productID, width: width, height: height)
                } catch {
                    fputs("warning: could not remember resolution choice for \(info.name): \(error)\n", stderr)
                }
            }
        }
    }

    private func printAvailableModes(_ info: DisplayInfo) {
        print("\(info.name) — HiDPI 'looks like' sizes available:")
        for m in ResolutionController.hiDPISizes(for: info.displayID) {
            let zoom = m.zoomPercent(nativeWidth: info.nativeWidth)
            print("  \(m.width)×\(m.height)  ·  \(zoom)%  (renders \(m.framebufferWidth)×\(m.framebufferHeight) @\(m.refreshRate)Hz)")
        }
    }
}
