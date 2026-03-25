import Foundation

/// Resolves the target `DisplayInfo` from an optional vendor:product string argument.
///
/// If `displayArg` is nil, returns the first connected external display.
/// Throws `ExtraDisplayError` if no display is found or the argument is malformed.
func resolveTargetDisplay(_ displayArg: String?) throws -> DisplayInfo {
    let allDisplays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

    guard !allDisplays.isEmpty else {
        throw ExtraDisplayError.noExternalDisplays
    }

    guard let displayArg else {
        // Default: first external display.
        return allDisplays[0]
    }

    let parts = displayArg.split(separator: ":").map(String.init)
    guard
        parts.count == 2,
        let vendorID  = UInt32(parts[0].trimmingCharacters(in: .whitespaces), radix: 16),
        let productID = UInt32(parts[1].trimmingCharacters(in: .whitespaces), radix: 16)
    else {
        throw ExtraDisplayError.displayNotFound(displayArg)
    }

    guard let match = allDisplays.first(where: {
        $0.vendorID == vendorID && $0.productID == productID
    }) else {
        throw ExtraDisplayError.displayNotFound(displayArg)
    }

    return match
}
