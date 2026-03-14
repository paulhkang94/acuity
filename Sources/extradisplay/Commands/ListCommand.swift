import ArgumentParser
import Foundation

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all connected external displays with their vendor/product IDs."
    )

    @Flag(name: .long, help: "Output as JSON array.")
    var json: Bool = false

    func run() throws {
        let displays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

        if displays.isEmpty {
            print("⚠ No external displays detected.")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let serializable = displays.map { SerializableDisplay($0) }
            let data = try encoder.encode(serializable)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("Connected external displays:\n")
            for (i, display) in displays.enumerated() {
                let hiDPIEnabled = PlistWriter.exists(
                    vendorID: display.vendorID,
                    productID: display.productID
                )
                let status = hiDPIEnabled ? "HiDPI ✓" : "HiDPI ✗"
                print(
                    "  \(i + 1). \(display.name)"
                    + "\n     ID         : \(String(format: "0x%04X", display.vendorID)):\(String(format: "0x%04X", display.productID))"
                    + "\n     Native     : \(display.nativeWidth)×\(display.nativeHeight)"
                    + "\n     Connection : \(display.connectionType)"
                    + "\n     Status     : \(status)\n"
                )
            }
        }
    }
}

// MARK: - JSON serialization

/// Encodable projection of DisplayInfo for `list --json`.
///
/// Fields match the documented schema:
///   vendorID, productID, name, resolution (WxH), hiDPIEnabled
private struct SerializableDisplay: Encodable {
    let name: String
    let vendorID: String
    let productID: String
    let resolution: String
    let connectionType: String
    let hiDPIEnabled: Bool

    init(_ info: DisplayInfo) {
        self.name           = info.name
        self.vendorID       = String(format: "0x%04X", info.vendorID)
        self.productID      = String(format: "0x%04X", info.productID)
        self.resolution     = "\(info.nativeWidth)x\(info.nativeHeight)"
        self.connectionType = info.connectionType.description
        self.hiDPIEnabled   = PlistWriter.exists(vendorID: info.vendorID, productID: info.productID)
    }
}
