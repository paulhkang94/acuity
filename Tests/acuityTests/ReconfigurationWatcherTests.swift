import XCTest

@testable import acuity

/// Regression tests for acu-007: stopWatching used to pass a fresh closure
/// literal to CGDisplayRemoveReconfigurationCallback, so the original
/// registration stayed live after "stop" (removal matches on the exact
/// (callback, userInfo) pair). With `passUnretained` userInfo, a display
/// event after deallocation would then be a use-after-free.
final class ReconfigurationWatcherTests: XCTestCase {

    private func makeStore() throws -> SelectionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acuity-watcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SelectionStore(fileURL: dir.appendingPathComponent("selections.json"))
    }

    /// start → stop → start → stop must be safe: with the acu-007 fix the
    /// removal uses the identical registered callback pointer, so repeated
    /// cycles neither leak registrations nor crash. (A real display event
    /// can't be simulated here; this guards the register/remove pairing and
    /// the idempotence contract.)
    func test_startStopCyclesAreSafeAndIdempotent() throws {
        let watcher = ReconfigurationWatcher(selectionStore: try makeStore())

        watcher.startWatching()
        watcher.startWatching()  // second start is a documented no-op
        watcher.stopWatching()
        watcher.stopWatching()   // second stop is a documented no-op

        watcher.startWatching()  // re-start after stop must also be safe
        watcher.stopWatching()
    }

    /// A watcher deallocated after stopWatching must not leave a live CG
    /// registration behind (the pre-fix behavior). We can only assert the
    /// deallocation path completes; the use-after-free itself needs a real
    /// hotplug event to trigger and is covered by the pointer-pairing fix.
    func test_deallocAfterStopDoesNotCrash() throws {
        var watcher: ReconfigurationWatcher? = ReconfigurationWatcher(selectionStore: try makeStore())
        watcher?.startWatching()
        watcher?.stopWatching()
        watcher = nil
    }
}
