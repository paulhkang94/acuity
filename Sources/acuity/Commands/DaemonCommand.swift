import ArgumentParser
import CoreFoundation
import Foundation

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the background display-reconfiguration daemon (started by launchd).",
        shouldDisplay: false
    )

    func run() throws {
        let version = ExtraDisplay.configuration.version
        fputs("[acuity] daemon starting — version \(version)\n", stderr)

        let watcher = ReconfigurationWatcher()
        watcher.startWatching()

        // Block forever on the CoreFoundation run loop.
        // launchd's KeepAlive will restart the process if it exits unexpectedly.
        CFRunLoopRun()

        // Should not be reached in normal operation.
        watcher.stopWatching()
    }
}
