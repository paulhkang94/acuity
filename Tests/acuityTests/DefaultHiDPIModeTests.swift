import CoreGraphics
import XCTest
@testable import acuity

final class DefaultHiDPIModeTests: XCTestCase {
    private final class Mode {
        let candidate: ModeCandidate
        init(_ width: Int, _ height: Int, hz: Int = 60, hidpi: Bool = true, usable: Bool = true) {
            candidate = ModeCandidate(width: width, height: height, isHiDPI: hidpi,
                                      refreshRate: hz, usableForDesktopGUI: usable)
        }
    }

    func test_defaultChoosesWidthOverAreaAndKeepsTheExactFirstTieIncludingRate() throws {
        let wide = Mode(2560, 720, hz: 60)
        let modes = [Mode(1920, 1200), wide, Mode(2560, 1440, hz: 144)]
        var calls = 0
        let selected = try ResolutionController.applyDefaultHiDPI(
            modes: modes, describe: { $0.candidate }, displayName: "Test"
        ) { mode in calls += 1; return mode }
        XCTAssertTrue(selected === wide, "Do not sort by area or reselect a higher-Hz duplicate")
        XCTAssertEqual(calls, 1)
    }

    func test_defaultRejectsUnusableOneXAndInvalidCandidates() throws {
        let eligible = Mode(1600, 900)
        let modes = [Mode(4000, 2000, usable: false), Mode(3000, 2000, hidpi: false),
                     Mode(2800, 0), Mode(0, 1000), eligible]
        let selected = try ResolutionController.applyDefaultHiDPI(
            modes: modes, describe: { $0.candidate }, displayName: "Test", apply: { $0 }
        )
        XCTAssertTrue(selected === eligible)
        XCTAssertThrowsError(try ResolutionController.applyDefaultHiDPI(
            modes: Array(modes.dropLast()), describe: { $0.candidate }, displayName: "Test",
            apply: { _ in XCTFail("No eligible mode must not configure") }
        ))
        XCTAssertThrowsError(try ResolutionController.applyDefaultHiDPI(
            modes: [Mode](), describe: { $0.candidate }, displayName: "Test", apply: { $0 }
        ))
    }

    func test_transactionSuccessIsPermanentAndCurrentModeIsANoop() throws {
        for current in [true, false] {
            let recorder = TransactionRecorder()
            try ResolutionController.commitMode(alreadyCurrent: current, displayName: "Test",
                                                canApply: { true }, transaction: recorder.transaction)
            XCTAssertEqual(recorder.calls, current ? [] : ["begin", "configure", "complete"])
        }
    }

    func test_cancelledRememberedApplyStopsBeforeLookingUpAnUnavailableDisplay() {
        XCTAssertThrowsError(try ResolutionController.apply(
            width: 1920, height: 1080, hz: 120,
            toDisplayID: .max, displayName: "Cancelled fixture", canApply: { false }
        )) { error in
            guard case ResolutionController.ModeApplicationError.cancelled = error else {
                return XCTFail("Cancelled remembered work must stop before mode lookup: \(error)")
            }
        }
    }

    func test_transactionFailureCancelsOnlyAnUncompletedContext() {
        for failed in ["begin", "configure", "complete"] {
            let recorder = TransactionRecorder(failed: failed)
            XCTAssertThrowsError(try ResolutionController.commitMode(
                alreadyCurrent: false, displayName: "Test", canApply: { true }, transaction: recorder.transaction
            ))
            let expected = failed == "begin" ? ["begin"] :
                (failed == "configure" ? ["begin", "configure", "cancel"] : ["begin", "configure", "complete"])
            XCTAssertEqual(recorder.calls, expected, "Completion consumes its context even when it fails")
        }
    }

    func test_cancellationAtEachBoundaryNeverCommitsAndCleansOpenContext() {
        for stopAfter in [0, 1, 2] {
            let recorder = TransactionRecorder()
            XCTAssertThrowsError(try ResolutionController.commitMode(
                alreadyCurrent: false, displayName: "Test",
                canApply: { recorder.calls.count < stopAfter }, transaction: recorder.transaction
            ))
            let expected = stopAfter == 0 ? [] :
                (stopAfter == 1 ? ["begin", "cancel"] : ["begin", "configure", "cancel"])
            XCTAssertEqual(recorder.calls, expected)
        }
    }
}

private final class TransactionRecorder {
    var calls: [String] = []
    let failed: String?
    init(failed: String? = nil) { self.failed = failed }
    var transaction: DisplayModeTransaction<Int> {
        DisplayModeTransaction(
            begin: { self.calls.append("begin"); return (self.failed == "begin" ? .failure : .success, 17) },
            configure: { handle in
                XCTAssertEqual(handle, 17)
                self.calls.append("configure")
                return self.failed == "configure" ? .failure : .success
            },
            complete: { handle, scope in
                XCTAssertEqual(handle, 17)
                XCTAssertEqual(scope, .permanently)
                self.calls.append("complete")
                return self.failed == "complete" ? .failure : .success
            },
            cancel: { handle in XCTAssertEqual(handle, 17); self.calls.append("cancel") }
        )
    }
}
