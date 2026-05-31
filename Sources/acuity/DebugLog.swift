import Foundation

/// Emits a diagnostic line only when `ACUITY_DEBUG` is set in the environment.
///
/// Replaces ad-hoc `print(...)` instrumentation that previously leaked into
/// normal CLI and menubar output. Diagnostics stay available for development
/// (`ACUITY_DEBUG=1 acuity status`) without polluting user-facing output.
func acuityDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["ACUITY_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data((message() + "\n").utf8))
}
