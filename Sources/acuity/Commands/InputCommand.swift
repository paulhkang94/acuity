import ArgumentParser
import Foundation

struct InputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Switch the active input source via DDC/CI."
    )

    @Argument(
        help: "Input source: hdmi1, hdmi2, dp1, dp2, usbc."
    )
    var source: String

    @Option(
        name: .long,
        help: "Target display by vendor:product ID (hex, e.g. 0x10ac:0x41da). Defaults to first external display."
    )
    var display: String?

    // MARK: - Known source identifiers

    private static let sourceMap: [String: InputSource] = [
        "hdmi1": .hdmi1,
        "hdmi2": .hdmi2,
        "dp1":   .displayPort1,
        "dp2":   .displayPort2,
        "usbc":  .usbC,
    ]

    func run() throws {
        let lower = source.lowercased()
        guard let inputSource = Self.sourceMap[lower] else {
            let valid = Self.sourceMap.keys.sorted().joined(separator: ", ")
            throw AcuityError.ddcError(
                "Unknown input source '\(source)'. Valid options: \(valid)."
            )
        }

        let info = try resolveTargetDisplay(display)
        try DDCController.setInput(inputSource, display: info)
        print("✓ Input switched to \(inputSource.description) on \(info.name).")
    }
}
