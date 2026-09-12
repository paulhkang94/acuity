import XCTest
@testable import acuity

final class DisplayWorkSchedulerTests: XCTestCase {
    private let target = DisplayWorkTarget(displayID: 1, vendorID: 2, productID: 3)

    func test_addBurstReplacesEarlierWorkAndKeepsTwoSecondDelay() {
        let clock = ManualDisplayClock()
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in self.target })
        let session = work.start()
        var calls: [Int] = []
        work.enqueue(target, session: session) { _ in calls.append(1) }
        work.enqueue(target, session: session) { _ in calls.append(2) }
        XCTAssertEqual(clock.jobs.map(\.delay), [2, 2])
        XCTAssertTrue(clock.jobs[0].cancelled)
        clock.fire(0) // Deliberately fire cancelled callbacks too.
        clock.fire(1)
        XCTAssertEqual(calls, [2])
    }

    func test_removeAndStopInvalidateQueuedWorkAcrossRestart() {
        let clock = ManualDisplayClock()
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in self.target })
        let oldSession = work.start()
        var calls = 0
        work.enqueue(target, session: oldSession) { _ in calls += 1 }
        work.cancel(displayID: target.displayID, session: oldSession)
        clock.fire(0)
        work.enqueue(target, session: oldSession) { _ in calls += 1 }
        work.stop()
        let newSession = work.start()
        work.enqueue(target, session: newSession) { _ in calls += 1 }
        work.cancel(displayID: target.displayID, session: oldSession)
        clock.fire(1)
        clock.fire(2)
        XCTAssertEqual(calls, 1)
        work.enqueue(target, session: oldSession) { _ in XCTFail("Old startup must not enqueue into new session") }
        XCTAssertEqual(clock.jobs.count, 3)
    }

    func test_offlineOrReassignedIdentityNeverEntersApply() {
        let identities: [DisplayWorkTarget?] = [
            nil,
            DisplayWorkTarget(displayID: 1, vendorID: 99, productID: 3),
            DisplayWorkTarget(displayID: 1, vendorID: 2, productID: 99),
        ]
        for identity in identities {
            let clock = ManualDisplayClock()
            let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in identity })
            let session = work.start()
            work.enqueue(target, session: session) { _ in XCTFail("Stale identity must never apply") }
            clock.fire(0)
        }
    }

    func test_cancellationInsideRunningUnitInvalidatesLaterApplyChecksWithoutDeadlock() {
        let clock = ManualDisplayClock()
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in self.target })
        let session = work.start()
        work.enqueue(target, session: session) { canApply in
            XCTAssertTrue(canApply())
            work.cancel(displayID: self.target.displayID, session: session)
            XCTAssertFalse(canApply(), "Cancellation must block a later mode call in the same unit")
        }
        clock.fire(0)
    }

    func test_coldBootDoesNotReplaceHotplugStabilization() {
        let clock = ManualDisplayClock()
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in self.target })
        let session = work.start()
        var calls: [String] = []
        work.enqueue(target, session: session) { _ in calls.append("hotplug") }
        work.enqueue(target, after: 0, session: session, replacing: false) { _ in calls.append("boot") }
        XCTAssertEqual(clock.jobs.count, 1)
        clock.fire(0)
        XCTAssertEqual(calls, ["hotplug"])
    }
    func test_stopBetweenColdBootDisplayUnitsPreventsTheNextApply() {
        let clock = ManualDisplayClock()
        let second = DisplayWorkTarget(displayID: 2, vendorID: 2, productID: 3)
        let work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { id in
            id == 1 ? self.target : second
        })
        let session = work.start()
        var calls = 0
        work.enqueue(target, after: 0, session: session) { _ in calls += 1; work.stop() }
        work.enqueue(second, after: 0, session: session) { _ in XCTFail("Stopped boot work must not apply") }
        clock.fire(0)
        clock.fire(1)
        XCTAssertEqual(calls, 1)
    }

    func test_stopDuringIdentityLookupPreventsApplyWithoutHoldingTheLock() {
        let clock = ManualDisplayClock()
        var work: DisplayWorkScheduler!
        defer { work = nil }
        work = DisplayWorkScheduler(schedule: clock.schedule, currentTarget: { _ in
            work.stop()
            return self.target
        })
        let session = work.start()
        work.enqueue(target, session: session) { _ in XCTFail("Lookup raced stop") }
        clock.fire(0)
    }

    func test_stopBeforeCancellationHandleReturnsStillCancelsTheJob() {
        let clock = ManualDisplayClock()
        var work: DisplayWorkScheduler!
        defer { work = nil }
        work = DisplayWorkScheduler(schedule: { delay, operation in
            let cancel = clock.schedule(after: delay, operation: operation)
            work.stop()
            return cancel
        }, currentTarget: { _ in self.target })
        let session = work.start()
        work.enqueue(target, session: session) { _ in XCTFail("Scheduling raced stop") }
        XCTAssertTrue(clock.jobs[0].cancelled)
        clock.fire(0)
    }

}

final class ManualDisplayClock {
    final class Job {
        let delay: TimeInterval
        let operation: () -> Void
        var cancelled = false
        init(delay: TimeInterval, operation: @escaping () -> Void) {
            self.delay = delay
            self.operation = operation
        }
    }
    var jobs: [Job] = []
    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> () -> Void {
        let job = Job(delay: delay, operation: operation)
        jobs.append(job)
        return { job.cancelled = true }
    }
    func fire(_ index: Int) { jobs[index].operation() }
}
