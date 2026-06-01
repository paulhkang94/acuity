import ArgumentParser
import Foundation

struct BrightnessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightness",
        abstract: "Get or set display brightness (0–100) via DDC/CI."
    )

    @Argument(help: "Brightness value 0–100.")
    var value: Int

    @Option(
        name: .long,
        help: "Target display by vendor:product ID (hex, e.g. 0x10ac:0x41da). Defaults to first external display."
    )
    var display: String?

    func run() throws {
        guard (0...100).contains(value) else {
            throw AcuityError.ddcError("Brightness value \(value) is out of range 0–100.")
        }

        let info = try resolveTargetDisplay(display)
        try DDCController.setBrightness(value, display: info)
        print("✓ Brightness set to \(value) on \(info.name).")
    }
}
