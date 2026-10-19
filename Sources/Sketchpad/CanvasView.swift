import AppKit
import PaintCore

/// Shows the document's bitmap at 1 unit per pixel (the enclosing scroll view does the zooming)
/// and turns mouse input into tool operations.
final class CanvasView: NSView {
    private unowned let document: CanvasDocument
    private let state: EditorState
    private var cachedImage: CGImage?
    private var stroke: Stroke?

    /// Reports the pixel under the cursor, or `nil` when it leaves the canvas.
    var onCursorMove: ((PixelPoint?) -> Void)?
    var onZoomRequest: ((_ zoomIn: Bool, _ center: NSPoint) -> Void)?

    /// A drag in progress. `before` is the whole canvas as it was at mouse-down, used both to
    /// redraw rubber-band shapes and to build the undo snapshot once the drag ends.
    private struct Stroke {
        let tool: Tool
        let usesSecondary: Bool
        let start: PixelPoint
        var last: PixelPoint
        let before: [UInt32]
        var dirty = PixelRect.zero
        var shapeArea = PixelRect.zero
    }

    init(document: CanvasDocument, state: EditorState) {
        self.document = document
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: document.bitmap.width, height: document.bitmap.height))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func bitmapDidChange(_ rect: PixelRect?) {
        cachedImage = nil
        let size = NSSize(width: document.bitmap.width, height: document.bitmap.height)
        if frame.size != size { setFrameSize(size) }
        if let rect { setNeedsDisplay(rect.cgRect) } else { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if cachedImage == nil { cachedImage = document.bitmap.makeImage() }
        guard let image = cachedImage else { return }
        // Nearest-neighbor so zoomed-in pixels stay square.
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: state.tool == .magnifier ? .pointingHand : .crosshair)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Control-click is the trackpad's right click.
        begin(event, secondary: event.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with event: NSEvent) {
        begin(event, secondary: true)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        drag(event)
    }

    override func mouseUp(with event: NSEvent) {
        finishStroke()
    }

    override func rightMouseUp(with event: NSEvent) {
        finishStroke()
    }

    override func mouseMoved(with event: NSEvent) {
        reportCursor(pixel(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        onCursorMove?(nil)
    }

    private func pixel(for event: NSEvent) -> PixelPoint {
        let p = convert(event.locationInWindow, from: nil)
        return PixelPoint(x: Int(p.x.rounded(.down)), y: Int(p.y.rounded(.down)))
    }

    private func reportCursor(_ p: PixelPoint) {
        onCursorMove?(document.bitmap.contains(p) ? p : nil)
    }

    private func begin(_ event: NSEvent, secondary: Bool) {
        window?.makeFirstResponder(self)
        guard stroke == nil else { return }
        let p = pixel(for: event)
        let bitmap = document.bitmap

        switch state.tool {
        case .picker:
            guard bitmap.contains(p) else { return }
            if secondary { state.secondary = bitmap[p] } else { state.primary = bitmap[p] }
            state.tool = state.previousTool
        case .magnifier:
            onZoomRequest?(!secondary, convert(event.locationInWindow, from: nil))
        case .fill:
            let before = bitmap.copyPixels()
            let filled = bitmap.floodFill(at: p, with: secondary ? state.secondary : state.primary)
            commit(before: before, rect: filled, actionName: Tool.fill.title)
            bitmapDidChange(filled)
        case .pencil, .eraser, .line, .rectangle, .ellipse:
            stroke = Stroke(tool: state.tool, usesSecondary: secondary, start: p, last: p, before: bitmap.copyPixels())
            if state.tool.shapeKind == nil { extendStroke(to: p, constrained: false) }
        }
    }

    private func drag(_ event: NSEvent) {
        let p = pixel(for: event)
        reportCursor(p)
        extendStroke(to: p, constrained: event.modifierFlags.contains(.shift))
    }

    private func extendStroke(to p: PixelPoint, constrained: Bool) {
        guard var stroke else { return }
        let bitmap = document.bitmap
        let changed: PixelRect

        if let kind = stroke.tool.shapeKind {
            // Rubber band: put back what the previous preview covered, then draw the shape again.
            bitmap.restore(stroke.shapeArea, from: stroke.before)
            var end = p
            if constrained {
                end = kind == .line
                    ? Constraint.snap45(from: stroke.start, to: p)
                    : Constraint.square(from: stroke.start, to: p)
            }
            let drawn = bitmap.drawShape(kind, from: stroke.start, to: end, style: shapeStyle(for: stroke))
            changed = stroke.shapeArea.union(drawn)
            stroke.shapeArea = drawn
        } else {
            // The eraser paints with the background color, like Paint's left-button eraser.
            let color = stroke.tool == .eraser ? state.secondary : drawingColor(for: stroke)
            changed = bitmap.drawSquareLine(from: stroke.last, to: p, size: state.size, color: color)
            stroke.last = p
        }

        stroke.dirty = stroke.dirty.union(changed)
        self.stroke = stroke
        bitmapDidChange(changed)
    }

    private func finishStroke() {
        guard let stroke else { return }
        self.stroke = nil
        commit(before: stroke.before, rect: stroke.dirty, actionName: stroke.tool.title)
    }

    private func cancelStroke() {
        guard let stroke else { return }
        self.stroke = nil
        document.bitmap.restore(stroke.dirty, from: stroke.before)
        bitmapDidChange(stroke.dirty)
    }

    private func commit(before: [UInt32], rect: PixelRect, actionName: String) {
        let rect = rect.intersection(document.bitmap.bounds)
        guard !rect.isEmpty else { return }
        document.registerEdit(document.bitmap.snapshot(rect, from: before), actionName: actionName)
    }

    private func drawingColor(for stroke: Stroke) -> RGBA {
        stroke.usesSecondary ? state.secondary : state.primary
    }

    /// Left drag: outline in color 1, fill in color 2. Right drag swaps them.
    private func shapeStyle(for stroke: Stroke) -> ShapeStyle {
        let outline = drawingColor(for: stroke)
        let fill = stroke.usesSecondary ? state.primary : state.secondary
        return ShapeStyle(
            outline: outline,
            fill: state.fillsShapes && stroke.tool != .line ? fill : nil,
            lineWidth: state.size
        )
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, stroke != nil { // Escape
            cancelStroke()
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased().first,
              let tool = Tool.allCases.first(where: { $0.shortcut == key })
        else {
            super.keyDown(with: event)
            return
        }
        state.tool = tool
    }
}
