import XCTest
@testable import acuity

/// Tests for the LaunchAgent plist generator.
///
/// Regression: the menubar agent shipped with `open -a` + KeepAlive=false, so
/// once the app exited it stayed dead. The menubar agent must launch the
/// bundle's inner binary directly and KeepAlive it.
final class AgentManagerTests: XCTestCase {

    private let bundleBinary = URL(fileURLWithPath: "/Users/x/Applications/Acuity.app/Contents/MacOS/acuity")

    // MARK: - Menubar (start) agent

    func test_startPlist_launchesBundleBinaryDirectly_notOpen() {
        let plist = AgentManager.buildPlist(executablePath: bundleBinary, command: "start")
        XCTAssertTrue(plist.contains("Applications/Acuity.app/Contents/MacOS/acuity"),
            "start agent must launch the bundle's inner binary")
        XCTAssertFalse(plist.contains("/usr/bin/open"),
            "must not use `open -a` — launchd cannot KeepAlive-supervise it")
        XCTAssertTrue(plist.contains("<string>start</string>"), "must pass the start subcommand")
    }

    func test_startPlist_keepAliveIsTrue() {
        let plist = AgentManager.buildPlist(executablePath: bundleBinary, command: "start")
        // The substring immediately following the KeepAlive key must be <true/>.
        guard let range = plist.range(of: "<key>KeepAlive</key>") else {
            return XCTFail("plist missing KeepAlive key")
        }
        let after = plist[range.upperBound...].prefix(40)
        XCTAssertTrue(after.contains("<true/>"),
            "menubar agent must KeepAlive=true so it cannot silently disappear")
        XCTAssertFalse(after.contains("<false/>"), "KeepAlive must not be false")
    }

    func test_startPlist_limitsToAquaSession() {
        let plist = AgentManager.buildPlist(executablePath: bundleBinary, command: "start")
        XCTAssertTrue(plist.contains("<key>LimitLoadToSessionType</key>"))
        XCTAssertTrue(plist.contains("<string>Aqua</string>"),
            "a status item needs the Aqua GUI session")
    }

    // MARK: - Daemon agent (unchanged)

    func test_daemonPlist_runsBinaryWithDaemonArg() {
        let cli = URL(fileURLWithPath: "/usr/local/bin/acuity")
        let plist = AgentManager.buildPlist(executablePath: cli, command: "daemon")
        XCTAssertTrue(plist.contains("/usr/local/bin/acuity"))
        XCTAssertTrue(plist.contains("<string>daemon</string>"))
    }

    func test_allPlists_areWellFormedXML() throws {
        for command in ["start", "daemon"] {
            let plist = AgentManager.buildPlist(executablePath: bundleBinary, command: command)
            let data = Data(plist.utf8)
            XCTAssertNoThrow(
                try PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                "\(command) plist must be valid, parseable XML"
            )
        }
    }
}
