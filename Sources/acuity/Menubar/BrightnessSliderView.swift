import AppKit
import Foundation

/// Custom NSView used as NSMenuItem.view for the brightness row.
/// Debounces DDC writes so the monitor is only updated after the slider
/// has been idle for 150 ms.
///
/// When DDC is unavailable (e.g. display connected via Thunderbolt dock),
/// the slider is shown disabled with a tooltip explaining why.
public final class BrightnessSliderView: NSView {

    // MARK: - Subviews

    private let dimLabel: NSTextField
    private let brightLabel: NSTextField
    private let slider: NSSlider

    // MARK: - State

    private let ddc: DDCControlling
    private let display: DisplayInfo
    private let ddcAvailable: Bool
    private var debounceItem: DispatchWorkItem?

    // MARK: - Init

    public init(ddc: DDCControlling, display: DisplayInfo, currentBrightness: Int, ddcAvailable: Bool) {
        self.ddc = ddc
        self.display = display
        self.ddcAvailable = ddcAvailable

        dimLabel    = NSTextField(labelWithString: "☀")
        brightLabel = NSTextField(labelWithString: "☀")
        slider      = NSSlider()

        super.init(frame: .zero)

        dimLabel.font = NSFont.systemFont(ofSize: 11)
        dimLabel.isEditable = false; dimLabel.isBordered = false; dimLabel.backgroundColor = .clear
        addSubview(dimLabel)

        brightLabel.font = NSFont.systemFont(ofSize: 16)
        brightLabel.isEditable = false; brightLabel.isBordered = false; brightLabel.backgroundColor = .clear
        addSubview(brightLabel)

        slider.minValue = 0
        slider.maxValue = 100
        slider.intValue = Int32(min(100, max(0, currentBrightness)))
        slider.controlSize = .small
        addSubview(slider)

        if ddcAvailable {
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
        } else {
            // Disable the slider — dragging would silently do nothing.
            // Tooltip explains the reason instead of leaving the user confused.
            slider.isEnabled = false
            let tooltip = "DDC/CI brightness control is not available for this display. " +
                          "This typically happens when monitors are connected through a Thunderbolt dock. " +
                          "Try connecting directly via USB-C or Thunderbolt."
            slider.toolTip = tooltip
            dimLabel.toolTip = tooltip
            brightLabel.toolTip = tooltip
            dimLabel.alphaValue = 0.4
            brightLabel.alphaValue = 0.4
        }

        translatesAutoresizingMaskIntoConstraints = false
        dimLabel.translatesAutoresizingMaskIntoConstraints = false
        brightLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            dimLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dimLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: dimLabel.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: brightLabel.leadingAnchor, constant: -6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            brightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            brightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Slider action

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Int(sender.intValue)
        print("PHK BrightnessSliderView.sliderChanged: value=\(value) display=\(display.displayID)")

        debounceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("PHK BrightnessSliderView: firing debounced DDC write value=\(value)")
            do {
                try self.ddc.setBrightness(value, display: self.display)
                print("PHK BrightnessSliderView: DDC write succeeded ✓")
                BezelOverlay.showBrightness(Float(value) / 100.0)
            } catch {
                print("PHK BrightnessSliderView: DDC write FAILED — \(error)")
                fputs("[acuity] BrightnessSliderView: DDC error: \(error)\n", stderr)
            }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Public

    public func setSliderValue(_ value: Int) {
        slider.intValue = Int32(min(100, max(0, value)))
    }

    public var currentValue: Int { Int(slider.intValue) }
}
