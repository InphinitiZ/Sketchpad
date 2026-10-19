import AppKit
import PaintCore

/// Lays out one document window: tool sidebar, zoomable canvas, status bar.
final class CanvasWindowController: NSWindowController {
    private static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8]

    private let state = EditorState()
    private let canvasView: CanvasView
    private let scrollView = NSScrollView()
    private let cursorLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private var toolButtons: [Tool: NSButton] = [:]
    private let sizePopup = NSPopUpButton()
    private let fillCheckbox = NSButton(checkboxWithTitle: "Fill shapes", target: nil, action: nil)
    private let primarySwatch = ColorSwatch(size: 30)
    private let secondarySwatch = ColorSwatch(size: 30)
    /// Which swatch the shared color panel is editing.
    private var editingSecondary = false

    init(document: CanvasDocument) {
        canvasView = CanvasView(document: document, state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 360)
        super.init(window: window)

        buildLayout()
        window.center()

        document.onBitmapChange = { [weak self] rect in
            self?.canvasView.bitmapDidChange(rect)
            self?.updateStatus()
        }
        canvasView.onCursorMove = { [weak self] p in
            self?.cursorLabel.stringValue = p.map { "\($0.x), \($0.y) px" } ?? ""
        }
        canvasView.onZoomRequest = { [weak self] zoomIn, center in
            self?.stepZoom(up: zoomIn, centeredAt: center)
        }
        state.observe { [weak self] in self?.syncControls() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
        syncControls()
        updateStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.zoomLevels.first!
        scrollView.maxMagnification = Self.zoomLevels.last!
        // Paint's gray-blue workspace around the canvas.
        scrollView.backgroundColor = NSColor(srgbRed: 0.79, green: 0.84, blue: 0.91, alpha: 1)
        scrollView.drawsBackground = true

        let sidebar = makeSidebar()
        let statusBar = NSStackView(views: [cursorLabel, NSView(), sizeLabel, zoomLabel])
        statusBar.spacing = 24
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for label in [cursorLabel, sizeLabel, zoomLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }

        for view in [sidebar, scrollView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 150),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func makeSidebar() -> NSView {
        var toolRows: [[NSView]] = []
        for pairStart in stride(from: 0, to: Tool.allCases.count, by: 2) {
            toolRows.append(Tool.allCases[pairStart..<min(pairStart + 2, Tool.allCases.count)].map(makeToolButton))
        }
        let toolGrid = NSGridView(views: toolRows)
        toolGrid.rowSpacing = 4
        toolGrid.columnSpacing = 4

        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))
        fillCheckbox.target = self
        fillCheckbox.action = #selector(fillToggled(_:))

        primarySwatch.onClick = { [weak self] _ in self?.editColor(secondary: false) }
        secondarySwatch.onClick = { [weak self] _ in self?.editColor(secondary: true) }
        let colorPair = NSStackView(views: [
            labeled(primarySwatch, "Color 1"),
            labeled(secondarySwatch, "Color 2"),
        ])
        colorPair.spacing = 12

        // Left click sets color 1, right click color 2, as in Paint.
        let swatches = ClassicPalette.colors.map { color -> NSView in
            let swatch = ColorSwatch(size: 20)
            swatch.color = color
            swatch.onClick = { [weak self] secondary in
                if secondary { self?.state.secondary = color } else { self?.state.primary = color }
            }
            return swatch
        }
        let paletteRows = stride(from: 0, to: swatches.count, by: 5).map { Array(swatches[$0..<$0 + 5]) }
        let palette = NSGridView(views: paletteRows)
        palette.rowSpacing = 3
        palette.columnSpacing = 3

        let stack = NSStackView(views: [
            heading("Tools"), toolGrid,
            heading("Size"), sizePopup, fillCheckbox,
            heading("Colors"), colorPair, palette,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.setCustomSpacing(14, after: toolGrid)
        stack.setCustomSpacing(14, after: fillCheckbox)
        return stack
    }

    private func makeToolButton(_ tool: Tool) -> NSButton {
        let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)!
        let button = NSButton(image: image, target: self, action: #selector(toolClicked(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .smallSquare
        button.tag = tool.rawValue
        button.toolTip = tool.shortcut.map { "\(tool.title) (\($0.uppercased()))" } ?? tool.title
        button.widthAnchor.constraint(equalToConstant: 56).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolButtons[tool] = button
        return button
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labeled(_ view: NSView, _ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [view, label])
        stack.orientation = .vertical
        stack.spacing = 2
        return stack
    }

    // MARK: - State

    private func syncControls() {
        for (tool, button) in toolButtons {
            button.state = tool == state.tool ? .on : .off
        }

        let options = state.tool.sizeOptions
        sizePopup.removeAllItems()
        sizePopup.addItems(withTitles: options.isEmpty ? ["—"] : options.map { "\($0) px" })
        sizePopup.isEnabled = !options.isEmpty
        if let index = options.firstIndex(of: state.size) { sizePopup.selectItem(at: index) }

        fillCheckbox.state = state.fillsShapes ? .on : .off
        fillCheckbox.isEnabled = state.tool == .rectangle || state.tool == .ellipse

        primarySwatch.color = state.primary
        secondarySwatch.color = state.secondary
        window?.invalidateCursorRects(for: canvasView)
    }

    private func updateStatus() {
        guard let bitmap = (document as? CanvasDocument)?.bitmap else { return }
        sizeLabel.stringValue = "\(bitmap.width) × \(bitmap.height) px"
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    @objc private func toolClicked(_ sender: NSButton) {
        state.tool = Tool(rawValue: sender.tag) ?? .pencil
        // Re-sync so clicking the active tool does not toggle it off.
        syncControls()
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        let options = state.tool.sizeOptions
        guard options.indices.contains(sender.indexOfSelectedItem) else { return }
        state.size = options[sender.indexOfSelectedItem]
    }

    @objc private func fillToggled(_ sender: NSButton) {
        state.fillsShapes = sender.state == .on
    }

    private func editColor(secondary: Bool) {
        editingSecondary = secondary
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = (secondary ? state.secondary : state.primary).nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let color = RGBA(sender.color) else { return }
        if editingSecondary { state.secondary = color } else { state.primary = color }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        stepZoom(up: true, centeredAt: nil)
    }

    @objc func zoomOut(_ sender: Any?) {
        stepZoom(up: false, centeredAt: nil)
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        scrollView.magnification = 1
        updateStatus()
    }

    @objc private func magnificationChanged() {
        updateStatus()
    }

    private func stepZoom(up: Bool, centeredAt center: NSPoint?) {
        let current = scrollView.magnification
        let next = up
            ? Self.zoomLevels.first { $0 > current + 0.001 }
            : Self.zoomLevels.last { $0 < current - 0.001 }
        guard let next else { return }
        if let center {
            scrollView.setMagnification(next, centeredAt: center)
        } else {
            scrollView.magnification = next
        }
        updateStatus()
    }
}

/// Keeps a canvas smaller than the window pinned to the top-left corner, as Paint does.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A clickable color square. Reports whether the click was secondary (right or control-click).
final class ColorSwatch: NSView {
    var color: RGBA = .black {
        didSet { needsDisplay = true }
    }

    var onClick: ((_ secondary: Bool) -> Void)?
    private let side: CGFloat

    init(size: CGFloat) {
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func draw(_ dirtyRect: NSRect) {
        color.nsColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(true)
    }
}
