import ArgumentParser
import Foundation

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Acuity LaunchAgent so HiDPI re-applies automatically on login."
    )

    func run() throws {
        // AppKit (linked for the menubar) cannot connect to WindowServer as root —
        // macOS SIGKILLs any root process that loads it. install/uninstall only
        // write to ~/Library/LaunchAgents and bootstrap the user's launchd domain;
        // neither needs root. Only `sudo acuity enable` requires elevation.
        if getuid() == 0 {
            fputs("error: do not run 'acuity install' with sudo.\n", stderr)
            fputs("Only 'sudo acuity enable' requires root.\n", stderr)
            fputs("Run: acuity install\n", stderr)
            throw ExitCode.failure
        }
        print("Installing Acuity LaunchAgent...\n")

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
            .appendingPathComponent("Applications/Acuity.app/Contents/MacOS/acuity")

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
            + " Acuity will automatically apply HiDPI settings on future logins."
        )
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the Acuity LaunchAgent."
    )

    @Flag(
        name: .long,
        help: "Also remove all HiDPI override plists from /Library/Displays/."
    )
    var clean: Bool = false

    func run() throws {
        print("Uninstalling Acuity LaunchAgent...\n")

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

        // Step 3: Optionally remove acuity's override plists.
        // Only files carrying acuity's ownership marker (target-default-ppmm,
        // see PlistWriter) are deleted; overrides other tools wrote are left
        // alone. Failures are reported per file, never counted as removals.
        if clean {
            print("\n  Removing HiDPI override plists (--clean)...")
            let result = PlistWriter.cleanAcuityOverrides()

            for url in result.removed {
                print("  ✓ Removed \(url.path)")
            }
            for url in result.skippedForeign {
                print("  ℹ Skipped \(url.path) — not written by acuity.")
            }
            var sawPermissionError = false
            for failure in result.failed {
                print("  ✗ Could not remove \(failure.url.path): \(failure.error.localizedDescription)")
                if isPermissionError(failure.error) { sawPermissionError = true }
            }

            if result.removed.isEmpty && result.skippedForeign.isEmpty && result.failed.isEmpty {
                print("  ℹ No override plists found — nothing to clean.")
            } else if result.failed.isEmpty {
                print("  ✓ Removed \(result.removed.count) override plist(s).")
            } else {
                print("  ⚠ Removed \(result.removed.count), failed \(result.failed.count).")
                if sawPermissionError {
                    print("  → /Library/Displays is root-owned. Try: sudo acuity uninstall --clean")
                }
            }
        }

        print("\n✓ Uninstall complete. Reboot to deactivate any active HiDPI overrides.")
    }

    /// `true` when the error is a permission failure (Cocoa write-permission
    /// error or an underlying POSIX EACCES/EPERM).
    private func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
            return true
        }
        return false
    }
}
