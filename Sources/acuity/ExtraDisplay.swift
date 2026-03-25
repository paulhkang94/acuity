import ArgumentParser
import Foundation


struct ExtraDisplay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acuity",
        abstract: "Enable HiDPI scaling on external monitors without SIP or private entitlements.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            StatusCommand.self,
            EnableCommand.self,
            DisableCommand.self,
            BrightnessCommand.self,
            ContrastCommand.self,
            InputCommand.self,
            DaemonCommand.self,
            StartCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
        ]
    )
}
