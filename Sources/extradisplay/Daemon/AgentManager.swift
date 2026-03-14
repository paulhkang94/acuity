import Foundation

/// Manages the extradisplay LaunchAgent that keeps HiDPI overrides active across reboots.
///
/// The agent runs `extradisplay daemon` at login and restarts on crash (KeepAlive).
/// stdout/stderr are redirected to /tmp/extradisplay.log for diagnostics.
public struct AgentManager {

    // MARK: - Constants

    public static let agentLabel = "com.extradisplay.agent"

    public static var plistPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
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

        // Load the agent without requiring a reboot.
        try runLaunchctl(["load", plistPath.path])
        fputs("[extradisplay] LaunchAgent installed and loaded: \(plistPath.path)\n", stderr)
    }

    // MARK: - Uninstall

    /// Unloads and removes the LaunchAgent plist.
    public static func uninstall() throws {
        if isInstalled {
            // Unload first; ignore errors if it was never loaded.
            _ = try? runLaunchctl(["unload", plistPath.path])
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
                <string>daemon</string>
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
