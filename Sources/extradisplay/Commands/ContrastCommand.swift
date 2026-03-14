import ArgumentParser
import Foundation

struct ContrastCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contrast",
        abstract: "Get or set display contrast (0–100) via DDC/CI."
    )

    @Argument(help: "Contrast value 0–100.")
    var value: Int

    @Option(
        name: .long,
        help: "Target display by vendor:product ID (hex, e.g. 0x10ac:0x41da). Defaults to first external display."
    )
    var display: String?

    func run() throws {
        guard (0...100).contains(value) else {
            throw ExtraDisplayError.ddcError("Contrast value \(value) is out of range 0–100.")
        }

        let info = try resolveTargetDisplay(display)
        try DDCController.setContrast(value, display: info)
        print("✓ Contrast set to \(value) on \(info.name).")
    }
}
