import Foundation
import IOKit.hid

// MARK: - HID usage constants

private let kHIDPage_Consumer: UInt32 = 0x000C
private let kHIDUsage_Csmr_BrightnessDecrement: UInt32 = 0x0070
private let kHIDUsage_Csmr_BrightnessIncrement: UInt32 = 0x006F

/// Intercepts system brightness key events (consumer usage page) and routes to DDC.
/// Graceful no-op if IOHIDManager setup fails (e.g., no Accessibility permission).
public final class BrightnessKeyInterceptor {

    // MARK: - State

    private var manager: IOHIDManager?
    let ddc: DDCControlling // internal for @testable access in tests
    private let step = 10 // brightness delta per key press

    // MARK: - Init

    public init(ddc: DDCControlling) {
        self.ddc = ddc
    }

    // MARK: - Lifecycle

    /// Call after NSApplication is running.
    /// Returns false if IOHIDManager setup fails.
    @discardableResult
    public func start() -> Bool {
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Build matching dictionaries for brightness increment and decrement keys
        let decrementMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey: kHIDUsage_Csmr_BrightnessDecrement,
        ]
        let incrementMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey: kHIDUsage_Csmr_BrightnessIncrement,
        ]

        IOHIDManagerSetDeviceMatchingMultiple(
            hidManager,
            [decrementMatch, incrementMatch] as CFArray
        )

        // Register the input value callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, brightnessKeyCallback, selfPtr)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            fputs("[acuity] BrightnessKeyInterceptor: IOHIDManagerOpen failed (\(openResult)) — brightness keys disabled.\n", stderr)
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }

        self.manager = hidManager
        fputs("[acuity] BrightnessKeyInterceptor: listening for brightness keys.\n", stderr)
        return true
    }

    /// Stops intercepting brightness keys and releases resources.
    public func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
    }

    // MARK: - DDC handler

    /// Called on each brightness key event. Adjusts DDC brightness on all external displays.
    fileprivate func handleBrightnessKey(usage: UInt32) {
        let displays = DisplayEnumerator.allDisplays().filter { !$0.isBuiltIn }
        for display in displays {
            let current = (try? ddc.getBrightness(display: display)) ?? 50
            let delta = usage == kHIDUsage_Csmr_BrightnessIncrement ? step : -step
            let newValue = min(100, max(0, current + delta))
            do {
                try ddc.setBrightness(newValue, display: display)
                BezelOverlay.showBrightness(Float(newValue) / 100.0)
            } catch {
                fputs("[acuity] BrightnessKeyInterceptor: DDC error for \(display.name): \(error)\n", stderr)
            }
        }
    }
}

// MARK: - C callback (must be a free function)

private func brightnessKeyCallback(
    context: UnsafeMutableRawPointer?,
    result _: IOReturn,
    sender _: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let interceptor = Unmanaged<BrightnessKeyInterceptor>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    // Only act on key-down events (value == 1)
    guard intValue == 1 else { return }
    guard usage == kHIDUsage_Csmr_BrightnessIncrement || usage == kHIDUsage_Csmr_BrightnessDecrement else { return }

    interceptor.handleBrightnessKey(usage: usage)
}
