import AppKit
import PaintCore

/// Paint's status bar: pointer position, selection size, canvas size and file size on the left,
/// the zoom level with its −/slider/+ control on the right.
final class StatusBarView: NSView {
    /// Paint's zoom presets.
    static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 5, 6, 7, 8]

    let positionLabel = NSTextField(labelWithString: "")
    let selectionLabel = NSTextField(labelWithString: "")
    let canvasLabel = NSTextField(labelWithString: "")
    let fileSizeLabel = NSTextField(labelWithString: "")
    let zoomLabel = NSTextField(labelWithString: "")
    let zoomSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let minus = NSButton()
    private let plus = NSButton()

    /// Asks for a zoom level (from the slider) or a step (from − and +).
    var onZoom: ((CGFloat) -> Void)?
    var onZoomStep: ((_ up: Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let panes = [
            pane("plus.viewfinder", positionLabel, localized("Pointer position")),
            pane("rectangle.dashed", selectionLabel, localized("Selection size")),
            pane("rectangle", canvasLabel, localized("Canvas size")),
            pane("internaldrive", fileSizeLabel, localized("File size")),
        ]
        for (button, symbol, up) in [(minus, "minus", false), (plus, "plus", true)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: up ? localized("Zoom in") : localized("Zoom out"))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = up ? #selector(stepUp) : #selector(stepDown)
            button.toolTip = up ? localized("Zoom in") : localized("Zoom out")
        }
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderMoved)
        zoomSlider.controlSize = .small
        zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        zoomSlider.setAccessibilityLabel(localized("Zoom"))
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let left = NSStackView(views: panes)
        left.spacing = 18
        let right = NSStackView(views: [zoomLabel, minus, zoomSlider, plus])
        right.spacing = 4
        for label in [positionLabel, selectionLabel, canvasLabel, fileSizeLabel, zoomLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byClipping
        }
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
        ])
        // Panes give way from the right when the window is narrow, as Paint hides them.
        left.setClippingResistancePriority(.defaultLow, for: .horizontal)
        left.detachesHiddenViews = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localized("Status Bar"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func pane(_ symbol: String, _ label: NSTextField, _ name: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        label.setAccessibilityLabel(name)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 4
        return stack
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Zoom

    /// Paint's slider: the middle is 100%, the left half runs linearly down to 12.5% and the
    /// right half up to 800% (`CAppletZoomControl::GetSliderPositionFromZoom`).
    static func sliderPosition(for zoom: CGFloat) -> Double {
        let low = zoomLevels.first!, high = zoomLevels.last!
        if zoom < 1 { return Double(50 * (zoom - low) / (1 - low)) }
        return Double(50 + 50 * (zoom - 1) / (high - 1))
    }

    static func zoom(forSliderPosition position: Double) -> CGFloat {
        let low = zoomLevels.first!, high = zoomLevels.last!
        let p = CGFloat(position)
        return p < 50 ? low + (1 - low) * p / 50 : 1 + (high - 1) * (p - 50) / 50
    }

    /// The preset nearest `zoom`, where a dragged slider settles.
    static func nearestPreset(to zoom: CGFloat) -> CGFloat {
        zoomLevels.min { abs($0 - zoom) < abs($1 - zoom) }!
    }

    func showZoom(_ zoom: CGFloat) {
        zoomLabel.stringValue = Self.percent(zoom) + "%"
        zoomSlider.doubleValue = Self.sliderPosition(for: zoom)
    }

    static func percent(_ zoom: CGFloat) -> String {
        let value = zoom * 100
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    @objc private func sliderMoved() {
        onZoom?(Self.nearestPreset(to: Self.zoom(forSliderPosition: zoomSlider.doubleValue)))
    }

    @objc private func stepUp() { onZoomStep?(true) }
    @objc private func stepDown() { onZoomStep?(false) }
}
