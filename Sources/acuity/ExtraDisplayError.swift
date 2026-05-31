import Foundation

/// Errors thrown by Acuity commands.
enum ExtraDisplayError: LocalizedError {
    case notRoot
    case noExternalDisplays
    case displayNotFound(String)
    case invalidDisplayArgument(String)
    case invalidPreset(String, valid: [String])
    case plistWriteFailed(String)
    case windowServerDefaultsFailed(Int32)
    case ddcNotSupported
    case ddcError(String)
    case resolutionNotAvailable(String)
    case setResolutionFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .notRoot:
            return "This command requires sudo. Run: sudo acuity \(CommandLine.arguments.dropFirst().joined(separator: " "))"
        case .noExternalDisplays:
            return "No external displays found."
        case .displayNotFound(let id):
            return "Display not found: \(id). Run 'acuity list' to see connected displays."
        case .invalidDisplayArgument(let arg):
            return "Invalid display argument '\(arg)'. Expected VendorID:ProductID in hex (e.g. 0x0410:0x8291)."
        case .invalidPreset(let name, let valid):
            return "Unknown preset '\(name)'. Valid options: \(valid.joined(separator: ", "))."
        case .plistWriteFailed(let reason):
            return "Failed to write HiDPI override plist: \(reason)"
        case .windowServerDefaultsFailed(let code):
            return "Failed to enable WindowServer HiDPI key (exit code \(code)). Ensure /Library/Preferences is writable."
        case .ddcNotSupported:
            return "DDC/CI is not supported on this display or connection type."
        case .ddcError(let reason):
            return "DDC error: \(reason)"
        case .resolutionNotAvailable(let detail):
            return "No usable HiDPI mode for \(detail). Run 'acuity set-resolution --list' to see available sizes."
        case .setResolutionFailed(let detail, let code):
            return "Failed to set resolution for \(detail) (CGError \(code))."
        }
    }
}
