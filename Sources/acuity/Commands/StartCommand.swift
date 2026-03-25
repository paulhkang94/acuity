import AppKit
import ArgumentParser
import Foundation

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the menubar app (runs in background, re-applies HiDPI on reconnect)."
    )

    // Append a line to /tmp/extradisplay.log so e2e tests and humans can verify startup.
    // `open -a` launched apps don't inherit launchd's stdout redirect, so we write explicitly.
    // User-owned log path so root daemon output can never block user writes.
    static let logPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("extradisplay.log")
    }()

    private static func log(_ message: String) {
        let line = "[acuity] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let ddc = DDCController()
        let controller = StatusMenuController(ddc: ddc)
        let keyInterceptor = BrightnessKeyInterceptor(ddc: ddc)

        // Start display reconfiguration watcher (same functionality as `extradisplay daemon`)
        let watcher = ReconfigurationWatcher()
        watcher.startWatching()

        DispatchQueue.main.async {
            controller.setup()
            let started = keyInterceptor.start()
            StartCommand.log("menubar started — BrightnessKeyInterceptor: \(started ? "listening for brightness keys" : "skipped (no Input Monitoring permission)")")
        }

        app.run()

        // Reached only after NSApplication exits
        watcher.stopWatching()
    }
}
