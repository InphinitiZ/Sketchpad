import AppKit
import PaintCore

/// A clickable color square: a palette color, or an empty custom slot (`color == nil`).
/// VoiceOver sees a button named after its color.
final class ColorSwatch: NSView {
    var color: RGBA? {
        didSet {
            needsDisplay = true
            toolTip = color.map(ClassicPalette.name(of:))
        }
    }

    /// Reports a click; `other` is Shift (Paint's Shift+click sets the other color slot).
    var onClick: ((_ other: Bool) -> Void)?
    private let side: CGFloat

    init(size: CGFloat, color: RGBA? = nil) {
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        defer { self.color = color }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func draw(_ dirtyRect: NSRect) {
        let square = bounds.insetBy(dx: 0.5, dy: 0.5)
        if let color {
            color.nsColor.setFill()
            square.fill()
            NSColor.separatorColor.setStroke()
        } else {
            // An unused custom slot: just its outline.
            NSColor.controlBackgroundColor.setFill()
            square.fill()
            NSColor.tertiaryLabelColor.setStroke()
        }
        NSBezierPath(rect: square).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard color != nil else { return }
        onClick?(event.modifierFlags.contains(.shift))
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { color.map(ClassicPalette.name(of:)) ?? localized("Empty custom color") }
    override func isAccessibilityEnabled() -> Bool { color != nil }

    override func accessibilityPerformPress() -> Bool {
        guard color != nil else { return false }
        onClick?(false)
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard color != nil else { return nil }
        return [NSAccessibilityCustomAction(name: localized("Set the Other Color")) { [weak self] in
            self?.onClick?(true)
            return true
        }]
    }
}

/// The ribbon's color gallery: Paint's 20 colors in two rows of 10, and a third row of 10
/// custom colors filled by Edit Colors.
final class PaletteView: NSStackView {
    private(set) var swatches: [ColorSwatch] = []
    private var customSwatches: [ColorSwatch] = []
    var onPick: ((_ color: RGBA, _ other: Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 3
        let colors: [RGBA?] = ClassicPalette.colors + Array(repeating: nil, count: EditorState.customColorSlots)
        for row in 0..<3 {
            let line = NSStackView()
            line.spacing = 3
            for column in 0..<10 {
                let swatch = ColorSwatch(size: 16, color: colors[row * 10 + column])
                swatch.onClick = { [weak self, weak swatch] other in
                    guard let color = swatch?.color else { return }
                    self?.onPick?(color, other)
                }
                swatches.append(swatch)
                if row == 2 { customSwatches.append(swatch) }
                line.addArrangedSubview(swatch)
            }
            addArrangedSubview(line)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localized("Colors"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showCustomColors(_ colors: [RGBA]) {
        for (index, swatch) in customSwatches.enumerated() {
            swatch.color = index < colors.count ? colors[index] : nil
        }
    }
}

/// OK and Cancel for the color panel while it stands in for Paint's Edit Colors dialog.
final class EditColorsAccessory: NSView {
    init(onFinish: @escaping (_ accepted: Bool) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let cancel = NSButton(title: localized("Cancel"), target: nil, action: nil)
        let ok = NSButton(title: localized("OK"), target: nil, action: nil)
        ok.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let actions = Actions(onFinish: onFinish)
        objc_setAssociatedObject(self, &Self.actionsKey, actions, .OBJC_ASSOCIATION_RETAIN)
        for (button, selector) in [(ok, #selector(Actions.accept)), (cancel, #selector(Actions.cancel))] {
            button.target = actions
            button.action = selector
        }
        let row = NSStackView(views: [cancel, ok])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static var actionsKey = 0

    private final class Actions: NSObject {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        @objc func accept() { onFinish(true) }
        @objc func cancel() { onFinish(false) }
    }
}
