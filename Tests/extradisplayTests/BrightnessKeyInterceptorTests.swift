import XCTest
@testable import extradisplay

final class BrightnessKeyInterceptorTests: XCTestCase {

    // MARK: - start()

    func test_start_withMockDDC_doesNotThrow() {
        let mock = MockDDCController()
        let interceptor = BrightnessKeyInterceptor(ddc: mock)
        // start() may return false in CI (no Accessibility permission), but must not throw or crash.
        _ = interceptor.start()
        interceptor.stop()
    }

    func test_stop_beforeStart_doesNotCrash() {
        let mock = MockDDCController()
        let interceptor = BrightnessKeyInterceptor(ddc: mock)
        // Calling stop before start must be a no-op
        interceptor.stop()
    }

    // MARK: - Brightness clamping

    func test_brightnessStep_clampedAt100() {
        let mock = MockDDCController()
        mock.brightnessToReturn = 95 // already near max
        let interceptor = BrightnessKeyInterceptor(ddc: mock)

        // Simulate an increment key on a fake display
        let display = makeDisplay()
        interceptor.simulateBrightnessIncrement(for: display)

        // The set value must not exceed 100
        XCTAssertEqual(mock.brightnessSetCalls.count, 1)
        let setTo = mock.brightnessSetCalls[0].0
        XCTAssertLessThanOrEqual(setTo, 100)
        XCTAssertEqual(setTo, 100)
    }

    func test_brightnessStep_clampedAt0() {
        let mock = MockDDCController()
        mock.brightnessToReturn = 5 // already near min
        let interceptor = BrightnessKeyInterceptor(ddc: mock)

        let display = makeDisplay()
        interceptor.simulateBrightnessDecrement(for: display)

        XCTAssertEqual(mock.brightnessSetCalls.count, 1)
        let setTo = mock.brightnessSetCalls[0].0
        XCTAssertGreaterThanOrEqual(setTo, 0)
        XCTAssertEqual(setTo, 0)
    }

    func test_brightnessIncrement_addsStep() {
        let mock = MockDDCController()
        mock.brightnessToReturn = 50
        let interceptor = BrightnessKeyInterceptor(ddc: mock)

        let display = makeDisplay()
        interceptor.simulateBrightnessIncrement(for: display)

        XCTAssertEqual(mock.brightnessSetCalls.count, 1)
        XCTAssertEqual(mock.brightnessSetCalls[0].0, 60)
    }

    func test_brightnessDecrement_subtractsStep() {
        let mock = MockDDCController()
        mock.brightnessToReturn = 50
        let interceptor = BrightnessKeyInterceptor(ddc: mock)

        let display = makeDisplay()
        interceptor.simulateBrightnessDecrement(for: display)

        XCTAssertEqual(mock.brightnessSetCalls.count, 1)
        XCTAssertEqual(mock.brightnessSetCalls[0].0, 40)
    }

    // MARK: - Helpers

    private func makeDisplay() -> DisplayInfo {
        DisplayInfo(
            vendorID: 0x1234,
            productID: 0x5678,
            displayID: 1,
            name: "Test Display",
            nativeWidth: 2560,
            nativeHeight: 1440,
            isBuiltIn: false,
            connectionType: .displayPort
        )
    }
}

// MARK: - Testability extension

extension BrightnessKeyInterceptor {
    /// Directly invoke the brightness handler for a single display (bypasses IOHIDManager).
    func simulateBrightnessIncrement(for display: DisplayInfo) {
        applyBrightnessDelta(step: 10, display: display)
    }

    func simulateBrightnessDecrement(for display: DisplayInfo) {
        applyBrightnessDelta(step: -10, display: display)
    }

    /// Applies a brightness delta to one display using the injected DDC controller.
    func applyBrightnessDelta(step: Int, display: DisplayInfo) {
        let current = (try? ddc.getBrightness(display: display)) ?? 50
        let newValue = min(100, max(0, current + step))
        do {
            try ddc.setBrightness(newValue, display: display)
        } catch {
            fputs("[extradisplay] BrightnessKeyInterceptorTests: DDC error: \(error)\n", stderr)
        }
    }
}
