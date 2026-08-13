import XCTest
@testable import acuity

/// Tests for `parseDisplayIDPair` — the shared vendor:product argument parser.
///
/// Regression: enable/disable/set-resolution each passed raw parts to
/// `UInt32(_:radix:16)`, which rejects a `0x` prefix — so the documented
/// `0xVID:0xPID` form (the exact string `acuity list` prints) always failed.
final class CommandHelpersTests: XCTestCase {

    // MARK: - Accepted forms

    func test_parse_acceptsREADMEExample_with0xPrefix() throws {
        // Exact ID string from README.md's `acuity list` demo output.
        let parsed = try parseDisplayIDPair("0x10AC:0x41DA")
        XCTAssertEqual(parsed.vendorID, 0x10AC)
        XCTAssertEqual(parsed.productID, 0x41DA)
    }

    func test_parse_acceptsBareHex_lowercase() throws {
        let parsed = try parseDisplayIDPair("10ac:41da")
        XCTAssertEqual(parsed.vendorID, 0x10AC)
        XCTAssertEqual(parsed.productID, 0x41DA)
    }

    func test_parse_acceptsUppercase0XPrefix_andMixedForms() throws {
        let parsed = try parseDisplayIDPair("0X10ac:41DA")
        XCTAssertEqual(parsed.vendorID, 0x10AC)
        XCTAssertEqual(parsed.productID, 0x41DA)
    }

    func test_parse_toleratesSurroundingWhitespace() throws {
        let parsed = try parseDisplayIDPair(" 0x0410 : 0x8291 ")
        XCTAssertEqual(parsed.vendorID, 0x0410)
        XCTAssertEqual(parsed.productID, 0x8291)
    }

    // MARK: - Malformed input → invalidDisplayArgument (never displayNotFound)

    func test_parse_malformedInputs_throwInvalidDisplayArgument() {
        let malformed = ["banana", "10ac", "10ac:41da:extra", "0x:0x", "zz:zz", ":", ""]
        for arg in malformed {
            XCTAssertThrowsError(try parseDisplayIDPair(arg), "'\(arg)' must be rejected") { error in
                guard case AcuityError.invalidDisplayArgument(let bad) = error else {
                    return XCTFail("'\(arg)' must throw invalidDisplayArgument, got \(error)")
                }
                XCTAssertEqual(bad, arg)
            }
        }
    }
}
