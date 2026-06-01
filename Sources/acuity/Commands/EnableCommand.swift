import ArgumentParser
import Foundation

struct EnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable HiDPI scaling for one or more external displays."
    )

    @Option(
        name: .long,
        help: "Target a specific display by vendor:product ID (hex, e.g. 0x0410:0x8291)."
    )
    var display: String?

    @Flag(
        name: .long,
        help: "Enable HiDPI on all connected non-Apple external displays."
    )
    var all: Bool = false

    @Option(
        name: .long,
        help: "Resolution preset: '2x' (half-native HiDPI), '1.5x' (1.5× HiDPI), 'all' (full resolution ladder). Defaults to '2x'."
    )
    var preset: String = "2x"

    func run() throws {
        try requireRoot()

        let scalingPreset: ScalingPreset
        switch preset {
        case "2x":   scalingPreset = .twoX
        case "1.5x": scalingPreset = .onePointFiveX
        case "all":  scalingPreset = .all
        default:
            throw AcuityError.invalidPreset(preset, valid: ["2x", "1.5x", "all"])
        }

        let allDisplays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

        if allDisplays.isEmpty {
            print("⚠ No external displays detected.")
            return
        }

        let targets: [DisplayInfo]
        if let displayArg = display {
            let parsed = try parseVendorProduct(displayArg)
            guard let match = allDisplays.first(where: {
                $0.vendorID == parsed.vendorID && $0.productID == parsed.productID
            }) else {
                throw AcuityError.displayNotFound(displayArg)
            }
            targets = [match]
        } else {
            targets = allDisplays
        }

        var successCount = 0
        var failureCount = 0

        for info in targets {
            let entries = DisplayPresets.forNativeResolution(
                width: info.nativeWidth,
                height: info.nativeHeight,
                preset: scalingPreset
            )
            do {
                try PlistWriter.write(
                    vendorID: info.vendorID,
                    productID: info.productID,
                    productName: info.name,
                    entries: entries
                )
                print("✓ HiDPI override written for \(info.name) (\(formatID(info.vendorID)):\(formatID(info.productID))). Reboot required to activate.")
                successCount += 1
            } catch {
                print("✗ Failed to write override for \(info.name): \(error.localizedDescription)")
                failureCount += 1
            }
        }

        try enableWindowServerHiDPI()

        if successCount > 0 {
            print("\n✓ Enabled HiDPI on \(successCount) display(s). Please reboot to activate.")
        }
        if failureCount > 0 {
            print("⚠ \(failureCount) display(s) failed. Check permissions on /Library/Displays/.")
        }
    }

    // MARK: - Private helpers

    private func requireRoot() throws {
        guard geteuid() == 0 else {
            throw AcuityError.notRoot
        }
    }

    private func parseVendorProduct(_ arg: String) throws -> (vendorID: UInt32, productID: UInt32) {
        let parts = arg.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let vendor = UInt32(parts[0].trimmingCharacters(in: .whitespaces), radix: 16),
              let product = UInt32(parts[1].trimmingCharacters(in: .whitespaces), radix: 16) else {
            throw AcuityError.invalidDisplayArgument(arg)
        }
        return (vendor, product)
    }

    private func formatID(_ id: UInt32) -> String {
        String(format: "0x%04X", id)
    }

    private func enableWindowServerHiDPI() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = [
            "write",
            "/Library/Preferences/com.apple.windowserver",
            "DisplayResolutionEnabled",
            "-bool", "YES",
        ]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw AcuityError.windowServerDefaultsFailed(task.terminationStatus)
        }
    }
}
