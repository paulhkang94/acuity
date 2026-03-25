import AppKit
import Foundation

/// Custom NSView used as NSMenuItem.view for the brightness row.
/// Debounces DDC writes so the monitor is only updated after the slider
/// has been idle for 150 ms.
public final class BrightnessSliderView: NSView {

    // MARK: - Subviews

    private let dimLabel: NSTextField
    private let brightLabel: NSTextField
    private let slider: NSSlider

    // MARK: - State

    private let ddc: DDCControlling
    private let display: DisplayInfo
    private var debounceItem: DispatchWorkItem?

    // MARK: - Init

    public init(ddc: DDCControlling, display: DisplayInfo, currentBrightness: Int) {
        self.ddc = ddc
        self.display = display

        dimLabel = NSTextField(labelWithString: "☀")
        brightLabel = NSTextField(labelWithString: "☀")
        slider = NSSlider()

        super.init(frame: .zero)

        // Dim icon (smaller font)
        dimLabel.font = NSFont.systemFont(ofSize: 11)
        dimLabel.isEditable = false
        dimLabel.isBordered = false
        dimLabel.backgroundColor = .clear
        addSubview(dimLabel)

        // Bright icon (larger font)
        brightLabel.font = NSFont.systemFont(ofSize: 16)
        brightLabel.isEditable = false
        brightLabel.isBordered = false
        brightLabel.backgroundColor = .clear
        addSubview(brightLabel)

        // Slider
        slider.minValue = 0
        slider.maxValue = 100
        slider.intValue = Int32(min(100, max(0, currentBrightness)))
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.controlSize = .small
        addSubview(slider)

        // Layout via Auto Layout
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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Slider action

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Int(sender.intValue)

        // Cancel any pending DDC write
        debounceItem?.cancel()

        // Schedule a new DDC write after 150 ms of slider idle time
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try self.ddc.setBrightness(value, display: self.display)
                BezelOverlay.showBrightness(Float(value) / 100.0)
            } catch {
                fputs("[acuity] BrightnessSliderView: DDC error: \(error)\n", stderr)
            }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Public

    /// Updates the slider position without triggering a DDC write.
    public func setSliderValue(_ value: Int) {
        slider.intValue = Int32(min(100, max(0, value)))
    }

    /// Current slider integer value.
    public var currentValue: Int { Int(slider.intValue) }
}
