import XCTest

class AppBundleTests: XCTestCase {
    func test_infoPlistExists() {
        let plist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // acuityTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path),
                      "Resources/Info.plist must exist for app bundle")
    }

    func test_infoPlistHasRequiredKeys() throws {
        let plist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        XCTAssertNotNil(dict["CFBundleIdentifier"])
        XCTAssertEqual(dict["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertTrue(dict["LSUIElement"] as? Bool ?? false,
                      "LSUIElement must be YES to hide from Dock")
    }
}
