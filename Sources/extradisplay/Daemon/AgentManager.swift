import Foundation

/// Manages the extradisplay LaunchAgent that keeps HiDPI overrides active across reboots.
///
/// The agent runs `extradisplay daemon` at login and restarts on crash (KeepAlive).
/// stdout/stderr are redirected to /tmp/extradisplay.log for diagnostics.
public struct AgentManager {

    // MARK: - Constants

    public static let agentLabel = "com.extradisplay.agent"

    public static var plistPath: URL {
        // When run via sudo, homeDirectoryForCurrentUser returns root's home.
        // Prefer SUDO_USER → /Users/<user> so the LaunchAgent lands in the
        // invoking user's Library, not /var/root/Library.
        let home: URL
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
           !sudoUser.isEmpty {
            home = URL(fileURLWithPath: "/Users/\(sudoUser)", isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    // MARK: - Install

    /// Installs the LaunchAgent plist and loads it into launchd.
    ///
    /// - Parameter executablePath: Absolute path to the `extradisplay` binary.
    ///   Typically `/usr/local/bin/extradisplay`.
    public static func install(executablePath: URL) throws {
        let launchAgentsDir = plistPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let plistContent = buildPlist(executablePath: executablePath)
        try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)

        // Use `launchctl bootstrap gui/<uid>` — the modern API that loads the
        // agent into the USER's GUI session. `launchctl load` (deprecated) runs
        // the agent as root, which causes macOS to SIGKILL any WindowServer
        // connection (menubar). SUDO_UID gives the invoking user's real UID when
        // this is called via sudo.
        let uid = realUserUID()
        try runLaunchctl(["bootstrap", "gui/\(uid)", plistPath.path])
        fputs("[extradisplay] LaunchAgent bootstrapped into gui/\(uid): \(plistPath.path)\n", stderr)
    }

    // MARK: - Uninstall

    /// Unloads and removes the LaunchAgent plist.
    public static func uninstall() throws {
        if isInstalled {
            let uid = realUserUID()
            _ = try? runLaunchctl(["bootout", "gui/\(uid)", plistPath.path])
            try FileManager.default.removeItem(at: plistPath)
            fputs("[extradisplay] LaunchAgent removed: \(plistPath.path)\n", stderr)
        } else {
            fputs("[extradisplay] LaunchAgent is not installed — nothing to remove.\n", stderr)
        }
    }

    // MARK: - Status

    /// `true` if the plist file exists on disk.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    /// `true` if launchd currently has the agent loaded and running.
    public static var isRunning: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments     = ["list", agentLabel]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Private helpers

    private static func buildPlist(executablePath: URL) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath.path)</string>
                <string>start</string>
            </array>

            <key>KeepAlive</key>
            <true/>

            <key>RunAtLoad</key>
            <true/>

            <key>StandardOutPath</key>
            <string>/tmp/extradisplay.log</string>

            <key>StandardErrorPath</key>
            <string>/tmp/extradisplay.log</string>
        </dict>
        </plist>
        """
    }

    /// Returns the real (non-root) UID of the invoking user.
    /// When run via sudo, SUDO_UID carries the original user's UID.
    private static func realUserUID() -> UInt32 {
        if let s = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = UInt32(s) {
            return uid
        }
        return getuid()
    }

    /// Runs a `launchctl` command and throws if it exits non-zero.
    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments     = args
        try task.run()
        task.waitUntilExit()
        let status = task.terminationStatus
        guard status == 0 else {
            throw AgentManagerError.launchctlFailed(args: args, exitCode: status)
        }
        return status
    }
}

// MARK: - Errors

public enum AgentManagerError: LocalizedError {
    case launchctlFailed(args: [String], exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .launchctlFailed(args, exitCode):
            return "launchctl \(args.joined(separator: " ")) failed with exit code \(exitCode)."
        }
    }
}
