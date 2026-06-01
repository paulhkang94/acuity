import ArgumentParser
import Foundation


struct Acuity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acuity",
        abstract: "Enable HiDPI scaling on external monitors without SIP or private entitlements.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            StatusCommand.self,
            EnableCommand.self,
            DisableCommand.self,
            SetResolutionCommand.self,
            DaemonCommand.self,
            StartCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
        ]
    )
}
