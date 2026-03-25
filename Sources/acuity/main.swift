import Foundation

// When launched from inside an app bundle (e.g., via LaunchAgent pointing to
// ~/Applications/Acuity.app/Contents/MacOS/acuity),
// default to `start` so the menubar launches automatically.
// All explicit subcommand invocations (e.g., `acuity list`) are unaffected.
// ParsableCommand.main(_ arguments:) takes the parse arguments WITHOUT argv[0].
// CommandLine.arguments[0] is the binary path — drop it before passing.
var parseArgs = Array(CommandLine.arguments.dropFirst())
if parseArgs.isEmpty, Bundle.main.bundlePath.hasSuffix(".app") {
    parseArgs = ["start"]
}
ExtraDisplay.main(parseArgs)
