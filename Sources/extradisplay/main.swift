import Foundation

// When launched from inside an app bundle (e.g., via LaunchAgent pointing to
// ~/Applications/ExtradisplayApp.app/Contents/MacOS/extradisplay),
// default to `start` so the menubar launches automatically.
// All explicit subcommand invocations (e.g., `extradisplay list`) are unaffected.
var args = CommandLine.arguments
if args.count == 1, Bundle.main.bundlePath.hasSuffix(".app") {
    args.append("start")
}
ExtraDisplay.main(args)
