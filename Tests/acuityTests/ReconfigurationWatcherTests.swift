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
    func test_stopRestartDropsQueuedMainInventoryFromOldLifetime() throws {
        let clock = ManualDisplayClock()
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in nil })
        var mainJobs: [() -> Void] = []
        var enumerations = 0
        var registrations = 0
        var removals = 0
        var context: UnsafeMutableRawPointer?
        let watcher = ReconfigurationWatcher(
            selectionStore: try makeStore(), work: work,
            enumerateDisplays: {
                XCTAssertTrue(Thread.isMainThread)
                enumerations += 1
                return []
            }, onMain: { mainJobs.append($0) },
            registerCallback: { _, pointer in registrations += 1; context = pointer; return .success },
            removeCallback: { _, pointer in
                XCTAssertEqual(pointer, context)
                removals += 1
                return .success
            }
        )
        watcher.startWatching()
        watcher.startWatching()
        watcher.stopWatching()
        watcher.startWatching()
        mainJobs[0]()
        XCTAssertEqual(enumerations, 0)
        mainJobs[1]()
        XCTAssertEqual(enumerations, 1)
        watcher.stopWatching()
        XCTAssertEqual(registrations, 2)
        XCTAssertEqual(removals, 2)
    }

    func test_removeEventCancelsDelayedApplyAndStopDropsQueuedNotifications() throws {
        let clock = ManualDisplayClock()
        let target = DisplayWorkTarget(displayID: 1, vendorID: 2, productID: 3)
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in target })
        var mainJobs: [() -> Void] = []
        var notifications = 0
        let watcher = ReconfigurationWatcher(
            selectionStore: try makeStore(), work: work, enumerateDisplays: { [] },
            onMain: { mainJobs.append($0) },
            registerCallback: { _, _ in .success }, removeCallback: { _, _ in .success }
        )
        watcher.onDisplayChange = { notifications += 1 }
        watcher.startWatching()
        watcher.handleDisplayChange(displayID: 1, flags: .addFlag)
        watcher.handleDisplayChange(displayID: 1, flags: .removeFlag)
        XCTAssertEqual(clock.jobs.count, 1)
        XCTAssertTrue(clock.jobs[0].cancelled)
        watcher.stopWatching()
        mainJobs.forEach { $0() }
        XCTAssertEqual(notifications, 0)
    }

    func test_failedRemovalCanBeRetriedWithoutDuplicateRegistration() throws {
        let work = DisplayWorkScheduler(currentTarget: { _ in nil })
        var removals = 0
        var registrations = 0
        let watcher = ReconfigurationWatcher(
            selectionStore: try makeStore(), work: work, enumerateDisplays: { [] }, onMain: { _ in },
            registerCallback: { _, _ in registrations += 1; return .success },
            removeCallback: { _, _ in
                removals += 1
                return removals == 1 ? .failure : .success
            }
        )
        watcher.startWatching()
        watcher.stopWatching()
        XCTAssertNil(work.currentSession)
        watcher.startWatching()
        XCTAssertEqual(registrations, 1)
        watcher.stopWatching()
        XCTAssertEqual(removals, 2)
    }

}
