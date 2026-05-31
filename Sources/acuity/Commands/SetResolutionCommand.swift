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
            guard !targets.isEmpty else { throw ExtraDisplayError.noExternalDisplays }
        } else {
            targets = [try resolveTargetDisplay(display)]
        }

        if list {
            for info in targets { printAvailableModes(info) }
            return
        }

        guard let width, let height else {
            throw ExtraDisplayError.invalidDisplayArgument("set-resolution needs --width and --height (or --list)")
        }

        for info in targets {
            let mode = try ResolutionController.apply(
                width: width, height: height, preferHiDPI: !noHidpi,
                toDisplayID: info.displayID, displayName: info.name
            )
            let kind = mode.pixelWidth > mode.width ? "HiDPI, sharp" : "1×, soft"
            print("✓ \(info.name) → looks like \(mode.width)×\(mode.height) "
                + "(renders \(mode.pixelWidth)×\(mode.pixelHeight) @\(Int(mode.refreshRate.rounded()))Hz · \(kind))")
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
