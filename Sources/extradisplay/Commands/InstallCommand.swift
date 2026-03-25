import ArgumentParser
import Foundation

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the extradisplay LaunchAgent so HiDPI re-applies automatically on login."
    )

    func run() throws {
        // AppKit (linked for the menubar) cannot connect to WindowServer as root —
        // macOS SIGKILLs any root process that loads it. install/uninstall only
        // write to ~/Library/LaunchAgents and bootstrap the user's launchd domain;
        // neither needs root. Only `sudo extradisplay enable` requires elevation.
        if getuid() == 0 {
            fputs("error: do not run 'extradisplay install' with sudo.\n", stderr)
            fputs("Only 'sudo extradisplay enable --all' requires root.\n", stderr)
            fputs("Run: extradisplay install\n", stderr)
            throw ExitCode.failure
        }
        print("Installing extradisplay LaunchAgent...\n")

        // Step 1: Locate the running binary so the plist references the correct path.
        let executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        print("  Binary: \(executableURL.path)")

        // Step 2: Write HiDPI override plists for all connected external displays
        //         if none exist yet (first-time setup convenience).
        let externalDisplays = DisplayEnumerator.allDisplays().filter { $0.isExternal }

        var wrotePlist = false
        for display in externalDisplays {
            guard !PlistWriter.exists(vendorID: display.vendorID, productID: display.productID) else {
                continue
            }
            do {
                let entries = DisplayPresets.forNativeResolution(
                    width:  display.nativeWidth,
                    height: display.nativeHeight,
                    preset: .all
                )
                try PlistWriter.write(
                    vendorID:    display.vendorID,
                    productID:   display.productID,
                    productName: display.name,
                    entries:     entries
                )
                print("  ✓ HiDPI override written for \(display.name)")
                wrotePlist = true
            } catch {
                print("  ⚠ Could not write override for \(display.name): \(error.localizedDescription)")
            }
        }

        if !wrotePlist && !externalDisplays.isEmpty {
            print("  ℹ HiDPI overrides already exist — skipping enable step.")
        }

        // Step 3: Install the LaunchAgent.
        // Prefer the app bundle binary (enables NSApplication / menubar via launchd).
        // Fall back to the CLI binary in daemon mode if the bundle isn't installed yet.
        let bundleBinary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Acuity.app/Contents/MacOS/extradisplay")

        let (launchPath, launchCommand): (URL, String) = {
            if FileManager.default.fileExists(atPath: bundleBinary.path) {
                return (bundleBinary, "start")
            } else {
                return (executableURL, "daemon")
            }
        }()

        if AgentManager.isInstalled {
            print("  ℹ LaunchAgent already installed at:\n    \(AgentManager.plistPath.path)")
        } else {
            do {
                try AgentManager.install(executablePath: launchPath, command: launchCommand)
                let modeStr = launchCommand == "start" ? "menubar (start)" : "headless (daemon)"
                print("  ✓ LaunchAgent installed [\(modeStr)]: \(AgentManager.plistPath.path)")
            } catch {
                throw error
            }
        }

        print(
            "\n✓ Installation complete."
            + " extradisplay will automatically apply HiDPI settings on future logins."
        )
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the extradisplay LaunchAgent."
    )

    @Flag(
        name: .long,
        help: "Also remove all HiDPI override plists from /Library/Displays/."
    )
    var clean: Bool = false

    func run() throws {
        print("Uninstalling extradisplay LaunchAgent...\n")

        // Step 1: Quit the running menubar app (if any).
        // open -a launched apps aren't managed by launchd directly, so removing
        // the LaunchAgent plist doesn't terminate them. Quit explicitly so that
        // a reinstall starts a fresh instance with the new binary.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "Acuity.app"]
        try? task.run(); task.waitUntilExit()

        // Step 2: Remove the LaunchAgent.
        if AgentManager.isInstalled {
            try AgentManager.uninstall()
            print("  ✓ LaunchAgent removed.")
        } else {
            print("  ℹ LaunchAgent is not installed — nothing to remove.")
        }

        // Step 2: Optionally remove all override plists.
        if clean {
            print("\n  Removing HiDPI override plists (--clean)...")
            let overridesBase = PlistWriter.overridesBasePath
            let fm = FileManager.default

            if fm.fileExists(atPath: overridesBase.path) {
                do {
                    let vendorDirs = try fm.contentsOfDirectory(
                        at: overridesBase,
                        includingPropertiesForKeys: nil
                    ).filter { $0.lastPathComponent.hasPrefix("DisplayVendorID-") }

                    var removed = 0
                    for vendorDir in vendorDirs {
                        let products = (try? fm.contentsOfDirectory(at: vendorDir, includingPropertiesForKeys: nil)) ?? []
                        for product in products where product.lastPathComponent.hasPrefix("DisplayProductID-") {
                            try? fm.removeItem(at: product)
                            removed += 1
                        }
                        try? fm.removeItem(at: vendorDir)
                    }
                    print("  ✓ Removed \(removed) override plist(s).")
                } catch {
                    print("  ⚠ Could not enumerate overrides: \(error.localizedDescription)")
                }
            } else {
                print("  ℹ No overrides directory found — nothing to clean.")
            }
        }

        print("\n✓ Uninstall complete. Reboot to deactivate any active HiDPI overrides.")
    }
}
