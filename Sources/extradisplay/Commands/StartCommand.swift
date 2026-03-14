import AppKit
import ArgumentParser
import Foundation

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the menubar app (runs in background, re-applies HiDPI on reconnect)."
    )

    func run() throws {
        // Detach from terminal so the process doesn't hold the shell.
        // Must be called before NSApplication.shared to avoid side effects.
        setsid()

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
            keyInterceptor.start()
        }

        app.run()

        // Reached only after NSApplication exits
        watcher.stopWatching()
    }
}
