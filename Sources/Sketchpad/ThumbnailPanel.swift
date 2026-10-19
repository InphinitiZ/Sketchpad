import AppKit
import PaintCore

/// Paint's Thumbnail window: the whole picture in miniature with the visible part outlined.
/// Clicking or dragging in it scrolls the canvas there.
final class ThumbnailPanel {
    let panel: NSPanel
    private let view = ThumbnailView()
    private weak var scrollView: NSScrollView?
    private let image: () -> CGImage?
    private var refreshQueued = false

    init(scrollView: NSScrollView, image: @escaping () -> CGImage?) {
        self.scrollView = scrollView
        self.image = image
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 170),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Thumbnail"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.contentView = view
        view.onJump = { [weak self] point in self?.scroll(centeredOn: point) }
    }

    var isVisible: Bool { panel.isVisible }

    func show(attachedTo window: NSWindow) {
        if panel.parent == nil {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 60))
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        refresh()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Redraws on the next turn of the run loop, so a drag's many changes cost one redraw.
    func setNeedsRefresh() {
        guard isVisible, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    func refresh() {
        guard isVisible, let scrollView else { return }
        view.image = image()
        view.visibleArea = scrollView.documentVisibleRect
        view.needsDisplay = true
    }

    private func scroll(centeredOn point: CGPoint) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        document.scroll(CGPoint(x: point.x - visible.width / 2, y: point.y - visible.height / 2))
        refresh()
    }
}

private final class ThumbnailView: NSView {
    var image: CGImage?
    /// The canvas area showing in the main window, in canvas pixels.
    var visibleArea = CGRect.zero
    var onJump: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    /// Where the picture sits in this view, scaled to fit with its aspect ratio kept.
    private var pictureFrame: CGRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let area = bounds.insetBy(dx: 6, dy: 6)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = pictureFrame
        context.saveGState()
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: frame)
        context.restoreGState()

        let scale = frame.width / CGFloat(image.width)
        let visible = CGRect(
            x: frame.minX + visibleArea.minX * scale,
            y: frame.minY + visibleArea.minY * scale,
            width: visibleArea.width * scale,
            height: visibleArea.height * scale
        ).intersection(frame)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: visible.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        jump(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        jump(to: event)
    }

    private func jump(to event: NSEvent) {
        guard let image else { return }
        let frame = pictureFrame
        let p = convert(event.locationInWindow, from: nil)
        let scale = CGFloat(image.width) / frame.width
        onJump?(CGPoint(x: (p.x - frame.minX) * scale, y: (p.y - frame.minY) * scale))
    }
}
