import ArgumentParser
import Foundation

struct DisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Remove HiDPI EDID overrides for one or more external displays."
    )

    @Option(
        name: .long,
        help: "Target a specific display by vendor:product ID (hex, e.g. 0x0410:0x8291)."
    )
    var display: String?

    @Flag(
        name: .long,
        help: "Remove HiDPI overrides for all connected non-Apple external displays."
    )
    var all: Bool = false

    func run() throws {
        try requireRoot()

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

        var removedCount = 0
        var notFoundCount = 0
        var failureCount = 0

        for info in targets {
            guard PlistWriter.exists(vendorID: info.vendorID, productID: info.productID) else {
                print("⚠ No override found for \(info.name) (\(formatID(info.vendorID)):\(formatID(info.productID))) — skipping.")
                notFoundCount += 1
                continue
            }

            do {
                try PlistWriter.remove(vendorID: info.vendorID, productID: info.productID)
                print("✓ HiDPI override removed for \(info.name) (\(formatID(info.vendorID)):\(formatID(info.productID))). Reboot required to deactivate.")
                removedCount += 1
            } catch {
                print("✗ Failed to remove override for \(info.name): \(error.localizedDescription)")
                failureCount += 1
            }
        }

        if removedCount > 0 {
            print("\n✓ Removed HiDPI override for \(removedCount) display(s). Please reboot to deactivate.")
        }
        if notFoundCount > 0 && removedCount == 0 && failureCount == 0 {
            print("ℹ No overrides were active for the specified display(s).")
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
}
