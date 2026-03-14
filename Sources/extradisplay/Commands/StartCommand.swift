import AppKit
import ArgumentParser
import Foundation

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the menubar app (runs in background, re-applies HiDPI on reconnect)."
    )

    func run() throws {
        // Do NOT call setsid() here. When launched via launchd (LaunchAgent),
        // setsid() creates a new session that strips the Mach bootstrap port
        // launchd injected — NSApplication then cannot connect to WindowServer
        // and exits EX_CONFIG (78). When run from Terminal, launchd is not the
        // parent so the bootstrap port is inherited differently and setsid()
        // appears harmless, masking the bug. launchd manages the lifecycle for
        // LaunchAgent runs; Terminal users can run `extradisplay start &` and
        // use disown if they want to detach from the shell.

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
