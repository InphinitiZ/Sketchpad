import AppKit
import PaintCore

/// Lays out one document window as Paint does: the ribbon on top, the canvas in its workspace,
/// the status bar at the bottom, and Save, Undo and Redo in the title bar.
final class CanvasWindowController: NSWindowController {
    let state = EditorState()
    let canvasView: CanvasView
    let workspace: CanvasWorkspaceView
    let scrollView = NSScrollView()
    let statusBar = StatusBarView()
    private var statusBarHeight: NSLayoutConstraint?
    private(set) var ribbon: RibbonView!
    /// The ribbon's controls that show state; set up in `buildRibbon`.
    var controls = RibbonControls()
    /// The Thumbnail option; the window itself only shows while zoomed in past 100%.
    private(set) var thumbnailEnabled = false
    private lazy var thumbnail = ThumbnailPanel(canvasView: canvasView) { [weak self] in
        (self?.document as? CanvasDocument)?.bitmap.makeImage()
    }
    private var fullScreen: FullScreenViewer?
    private var editingColors = false
    private var lastRulerMarks: (CGFloat, CGFloat)?

    init(document: CanvasDocument) {
        canvasView = CanvasView(document: document, state: state)
        workspace = CanvasWorkspaceView(canvasView: canvasView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self

        ribbon = buildRibbon()
        buildLayout()
        addQuickAccessToolbar()
        window.center()

        document.onBitmapChange = { [weak self] rect in
            self?.canvasView.documentDidChangeBitmap(rect)
            self?.updateStatus()
        }
        canvasView.onCursorMove = { [weak self] p in
            guard let self else { return }
            self.statusBar.positionLabel.stringValue = p.map { self.measure($0.x, $0.y, separator: ", ") } ?? ""
            self.markRulers(at: p)
        }
        canvasView.onZoomRequest = { [weak self] zoomIn, center in
            self?.magnify(in: zoomIn, at: center)
        }
        canvasView.onWheelZoom = { [weak self] zoomIn, center in
            guard let self else { return }
            self.stepZoom(up: zoomIn, centeredAt: self.workspace.convert(center, from: self.canvasView))
        }
        canvasView.onCanvasSizePreview = { [weak self] preview in
            guard let self else { return }
            if let preview {
                self.statusBar.canvasLabel.stringValue = self.measure(preview.width, preview.height, separator: " × ")
            } else {
                self.updateStatus()
            }
        }
        canvasView.onStatusChange = { [weak self] in self?.updateSelectionStatus() }
        canvasView.onDisplayChange = { [weak self] in self?.thumbnail.setNeedsRefresh() }
        statusBar.onZoom = { [weak self] zoom in self?.setZoom(zoom, centeredAt: nil) }
        statusBar.onZoomStep = { [weak self] up in self?.stepZoom(up: up, centeredAt: nil) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleAreaChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
        state.observe { [weak self] in self?.syncControls() }
        applySavedViewOptions()
        syncControls()
        updateStatus()
    }

    /// Restores the View options Paint remembers between runs.
    private func applySavedViewOptions() {
        scrollView.rulersVisible = Preferences.showRulers
        canvasView.showsGridlines = Preferences.showGrid
        statusBar.isHidden = !Preferences.showStatusBar
        statusBarHeight?.constant = statusBar.isHidden ? 0 : 24
        thumbnailEnabled = Preferences.showThumbnail
        applyUnit()
        window?.setFrameAutosaveName("Sketchpad Window")
    }

    /// Shows rulers and status bar measures in the unit chosen in Image Properties.
    func applyUnit() {
        let unit = Preferences.unit
        let dpi = canvasView.document.dotsPerInch
        let name = NSRulerView.UnitName("Sketchpad \(unit.rawValue) \(dpi)")
        NSRulerView.registerUnit(
            withName: name, abbreviation: unit.abbreviation, unitToPointsConversionFactor: unit.pixels(at: dpi),
            stepUpCycle: unit == .pixels ? [10] : [2], stepDownCycle: [0.5]
        )
        scrollView.horizontalRulerView?.measurementUnits = name
        scrollView.verticalRulerView?.measurementUnits = name
        // Gridline spacing follows the unit too.
        canvasView.needsDisplay = true
        updateStatus()
    }

    /// A pixel position or size in the current unit, as Paint's status bar writes it.
    private func measure(_ a: Int, _ b: Int, separator: String) -> String {
        let unit = Preferences.unit, dpi = canvasView.document.dotsPerInch
        return unit.format(a, at: dpi) + separator + unit.format(b, at: dpi) + unit.abbreviation
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The document is attached after `init` (by `addWindowController`), so the status bar
    /// fills in then.
    override var document: AnyObject? {
        didSet { updateStatus() }
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = workspace
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = StatusBarView.zoomLevels.first!
        scrollView.maxMagnification = StatusBarView.zoomLevels.last!
        // Paint's gray-blue workspace around the canvas.
        scrollView.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.17, green: 0.19, blue: 0.23, alpha: 1)
                : NSColor(srgbRed: 0.79, green: 0.84, blue: 0.91, alpha: 1)
        }
        scrollView.drawsBackground = true
        NSRulerView.registerUnit(
            withName: .pixels, abbreviation: "px", unitToPointsConversionFactor: 1,
            stepUpCycle: [10], stepDownCycle: [0.5]
        )
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.horizontalRulerView?.measurementUnits = .pixels
        scrollView.verticalRulerView?.measurementUnits = .pixels
        scrollView.rulersVisible = false

        for view in [ribbon!, scrollView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            ribbon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ribbon.topAnchor.constraint(equalTo: content.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: 24)
        statusBarHeight?.isActive = true
    }

    /// Paint's Quick Access Toolbar: Save, Undo and Redo beside the window title.
    private func addQuickAccessToolbar() {
        let buttons = [
            (localized("Save"), "square.and.arrow.down", #selector(NSDocument.save(_:))),
            (localized("Undo"), "arrow.uturn.backward", Selector(("undo:"))),
            (localized("Redo"), "arrow.uturn.forward", Selector(("redo:"))),
        ].map { title, symbol, action -> NSButton in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: nil, action: action)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = title
            return button
        }
        let bar = NSStackView(views: buttons)
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        bar.frame.size = bar.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .leading
        window?.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - Status

    func updateStatus() {
        let document = canvasView.document
        let bitmap = document.bitmap
        statusBar.canvasLabel.stringValue = measure(bitmap.width, bitmap.height, separator: " × ")
        statusBar.fileSizeLabel.stringValue = fileSizeText(document)
        statusBar.showZoom(scrollView.magnification)
        updateSelectionStatus()
    }

    /// The selection pane follows the selection, a shape being drawn or edited, or a box being
    /// dragged out.
    private func updateSelectionStatus() {
        statusBar.selectionLabel.stringValue = canvasView.statusSelectionSize.map {
            measure($0.width, $0.height, separator: " × ")
        } ?? ""
    }

    /// Marks the pointer's position on both rulers.
    private func markRulers(at p: PixelPoint?) {
        guard scrollView.rulersVisible, let horizontal = scrollView.horizontalRulerView, let vertical = scrollView.verticalRulerView else { return }
        let old = lastRulerMarks
        let new = p.map { point -> (CGFloat, CGFloat) in
            let location = workspace.convert(NSPoint(x: CGFloat(point.x) + 0.5, y: CGFloat(point.y) + 0.5), from: canvasView)
            return (location.x, location.y)
        }
        horizontal.moveRulerline(fromLocation: old.map { horizontal.convert(NSPoint(x: $0.0, y: 0), from: workspace).x } ?? -1,
                                 toLocation: new.map { horizontal.convert(NSPoint(x: $0.0, y: 0), from: workspace).x } ?? -1)
        vertical.moveRulerline(fromLocation: old.map { vertical.convert(NSPoint(x: 0, y: $0.1), from: workspace).y } ?? -1,
                               toLocation: new.map { vertical.convert(NSPoint(x: 0, y: $0.1), from: workspace).y } ?? -1)
        lastRulerMarks = new
    }

    /// Paint's "Size: 12.3KB", or "Size: None" before the picture is saved.
    private func fileSizeText(_ document: CanvasDocument) -> String {
        guard let size = (try? document.fileURL?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return localized("Size: None")
        }
        return localized(format: "Size: %@", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        stepZoom(up: true, centeredAt: nil)
    }

    @objc func zoomOut(_ sender: Any?) {
        stepZoom(up: false, centeredAt: nil)
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        setZoom(1, centeredAt: nil)
    }

    func stepZoom(up: Bool, centeredAt center: NSPoint?) {
        let current = scrollView.magnification
        let next = up
            ? StatusBarView.zoomLevels.first { $0 > current + 0.001 }
            : StatusBarView.zoomLevels.last { $0 < current - 0.001 }
        guard let next else { return }
        setZoom(next, centeredAt: center)
    }

    /// Changes the zoom. Like Paint's `SetZoom`, this first places a floating selection.
    func setZoom(_ zoom: CGFloat, centeredAt center: NSPoint?) {
        canvasView.commitSelection()
        if let center {
            scrollView.setMagnification(zoom, centeredAt: center)
        } else {
            scrollView.magnification = zoom
        }
        magnificationChanged()
    }

    /// The magnifier: zoom in so its preview rectangle fills the view, or zoom out.
    private func magnify(in zoomIn: Bool, at point: NSPoint) {
        guard zoomIn else {
            stepZoom(up: false, centeredAt: workspace.convert(point, from: canvasView))
            return
        }
        let target = canvasView.magnifierRect(at: point)
        stepZoom(up: true, centeredAt: nil)
        if let target { canvasView.scroll(target.origin) }
    }

    @objc private func magnificationChanged() {
        workspace.updateLayout()
        updateStatus()
        updateThumbnail()
        canvasView.needsDisplay = true
        // Brush and eraser pointers are drawn at the zoomed size.
        window?.invalidateCursorRects(for: canvasView)
    }

    @objc private func visibleAreaChanged() {
        thumbnail.setNeedsRefresh()
    }

    // MARK: - View tab

    @objc func toggleRulers(_ sender: Any?) {
        scrollView.rulersVisible.toggle()
        Preferences.showRulers = scrollView.rulersVisible
        lastRulerMarks = nil
        syncControls()
    }

    @objc func toggleGridlines(_ sender: Any?) {
        canvasView.showsGridlines.toggle()
        Preferences.showGrid = canvasView.showsGridlines
        syncControls()
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        statusBar.isHidden.toggle()
        Preferences.showStatusBar = !statusBar.isHidden
        statusBarHeight?.constant = statusBar.isHidden ? 0 : 24
        syncControls()
    }

    @objc func toggleThumbnail(_ sender: Any?) {
        thumbnailEnabled.toggle()
        Preferences.showThumbnail = thumbnailEnabled
        updateThumbnail()
        syncControls()
    }

    /// Paint shows the thumbnail only while the picture is zoomed in past 100%.
    private func updateThumbnail() {
        guard let window else { return }
        let wanted = thumbnailEnabled && scrollView.magnification > 1.001
        if wanted, !thumbnail.isVisible {
            thumbnail.show(attachedTo: window)
        } else if !wanted, thumbnail.isVisible {
            thumbnail.hide()
        } else {
            thumbnail.refresh()
        }
    }

    var thumbnailIsShowing: Bool { thumbnail.isVisible }

    /// Paint's Full Screen (F11): the picture alone; any key or click returns.
    @objc func showFullScreen(_ sender: Any?) {
        guard let image = (document as? CanvasDocument)?.bitmap.makeImage(), let screen = window?.screen ?? NSScreen.main else { return }
        canvasView.finishInteractions()
        let viewer = FullScreenViewer(image: image, screen: screen) { [weak self] in self?.fullScreen = nil }
        fullScreen = viewer
        viewer.show()
    }

    // MARK: - Colors

    /// Paint's Edit Colors: the color panel, opened modally on the active color with OK and
    /// Cancel; OK sets the color and adds it to the custom row.
    @objc func editColors(_ sender: Any?) {
        guard !editingColors else { return }
        editingColors = true
        defer { editingColors = false }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = (state.activeSlot == .primary ? state.primary : state.secondary).nsColor
        panel.accessoryView = EditColorsAccessory { accepted in
            NSApp.stopModal(withCode: accepted ? .OK : .cancel)
        }
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            NSApp.stopModal(withCode: .cancel)
        }
        let response = NSApp.runModal(for: panel)
        NotificationCenter.default.removeObserver(closing)
        panel.accessoryView = nil
        panel.orderOut(nil)
        if response == .OK, let color = RGBA(panel.color) { applyEditedColor(color) }
    }

    func applyEditedColor(_ color: RGBA) {
        state.choose(color)
        state.addCustomColor(color)
    }

    /// Edit menu item and ribbon option.
    @objc func toggleTransparentSelection(_ sender: Any?) {
        state.transparentSelection.toggle()
    }

    // MARK: - Format menu (the text tool)

    @objc func toggleBold(_ sender: Any?) { state.textStyle.bold.toggle() }
    @objc func toggleItalic(_ sender: Any?) { state.textStyle.italic.toggle() }
    @objc func toggleUnderline(_ sender: Any?) { state.textStyle.underline.toggle() }
    @objc func toggleStrikethrough(_ sender: Any?) { state.textStyle.strikethrough.toggle() }
}

extension CanvasWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleRulers(_:)):
            menuItem.state = scrollView.rulersVisible ? .on : .off
        case #selector(toggleGridlines(_:)):
            menuItem.state = canvasView.showsGridlines ? .on : .off
        case #selector(toggleStatusBar(_:)):
            menuItem.state = statusBar.isHidden ? .off : .on
        case #selector(toggleThumbnail(_:)):
            menuItem.state = thumbnailEnabled ? .on : .off
        case #selector(toggleTransparentSelection(_:)):
            menuItem.state = state.transparentSelection ? .on : .off
        case #selector(toggleBold(_:)):
            menuItem.state = state.textStyle.bold ? .on : .off
            return state.tool == .text
        case #selector(toggleItalic(_:)):
            menuItem.state = state.textStyle.italic ? .on : .off
            return state.tool == .text
        case #selector(toggleUnderline(_:)):
            menuItem.state = state.textStyle.underline ? .on : .off
            return state.tool == .text
        case #selector(toggleStrikethrough(_:)):
            menuItem.state = state.textStyle.strikethrough ? .on : .off
            return state.tool == .text
        default:
            break
        }
        return true
    }
}

extension CanvasWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        thumbnail.hide()
        // The next new picture gets this one's size, as in Paint.
        let bitmap = canvasView.document.bitmap
        Preferences.newPictureSize = (bitmap.width, bitmap.height)
    }
}

/// Keeps a canvas smaller than the window pinned to the top-left corner, as Paint does.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

extension NSRulerView.UnitName {
    static let pixels = NSRulerView.UnitName("Pixels")
}

/// Paint's full-screen view: the picture alone on black, at actual size or shrunk to fit.
final class FullScreenViewer: NSObject {
    private let window: NSWindow
    private let onClose: () -> Void

    init(image: CGImage, screen: NSScreen, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let fullScreenWindow = FullScreenWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window = fullScreenWindow
        super.init()
        window.backgroundColor = .black
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        let points = NSSize(width: CGFloat(image.width) / screen.backingScaleFactor, height: CGFloat(image.height) / screen.backingScaleFactor)
        let scale = min(1, screen.frame.width / points.width, screen.frame.height / points.height)
        let size = NSSize(width: points.width * scale, height: points.height * scale)
        let view = NSImageView(frame: NSRect(x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2, width: size.width, height: size.height))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(view)
        window.contentView = content
        fullScreenWindow.onDismiss = { [weak self] in self?.close() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        window.orderOut(nil)
        onClose()
    }
}

private final class FullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onDismiss?() }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
}
