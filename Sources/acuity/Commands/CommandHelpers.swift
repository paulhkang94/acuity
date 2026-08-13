import Foundation

/// Parses a `vendor:product` display argument in hex.
///
/// Accepts an optional `0x`/`0X` prefix on either part — the exact form that
/// `acuity list` prints (e.g. `0x10AC:0x41DA`) — as well as bare hex
/// (`10ac:41da`). This is the ONE shared parser used by enable, disable and
/// set-resolution; do not reintroduce per-command copies.
///
/// - Throws: `AcuityError.invalidDisplayArgument` when the string is malformed.
func parseDisplayIDPair(_ arg: String) throws -> (vendorID: UInt32, productID: UInt32) {
    let parts = arg.split(separator: ":").map(String.init)
    guard parts.count == 2,
          let vendorID = parseHexID(parts[0]),
          let productID = parseHexID(parts[1]) else {
        throw AcuityError.invalidDisplayArgument(arg)
    }
    return (vendorID, productID)
}

/// Parses one hex component, stripping an optional `0x`/`0X` prefix.
private func parseHexID(_ raw: String) -> UInt32? {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        s = String(s.dropFirst(2))
    }
    guard !s.isEmpty else { return nil }
    return UInt32(s, radix: 16)
}

/// Resolves the target `DisplayInfo` from an optional vendor:product string argument.
///
/// If `displayArg` is nil, returns the first connected external display.
/// Throws `AcuityError.invalidDisplayArgument` if the argument is malformed,
/// `AcuityError.displayNotFound` if no connected display matches it.
func resolveTargetDisplay(_ displayArg: String?) throws -> DisplayInfo {
    let allDisplays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

    guard !allDisplays.isEmpty else {
        throw AcuityError.noExternalDisplays
    }

    guard let displayArg else {
        // Default: first external display.
        return allDisplays[0]
    }

    let parsed = try parseDisplayIDPair(displayArg)

    guard let match = allDisplays.first(where: {
        $0.vendorID == parsed.vendorID && $0.productID == parsed.productID
    }) else {
        throw AcuityError.displayNotFound(displayArg)
    }

    return match
}
