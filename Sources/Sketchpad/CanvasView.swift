import AppKit
import PaintCore

/// Shows the document's bitmap at 1 unit per pixel (the enclosing scroll view does the zooming)
/// and turns mouse and keyboard input into tool operations.
final class CanvasView: NSView {
    unowned let document: CanvasDocument
    let state: EditorState
    private var cachedImage: CGImage?
    private var lastTool: Tool

    /// The mouse drag in progress, if any.
    var drag: Drag?
    /// The current selection, from when it is made until it is deselected.
    var selection: SelectionSession?
    /// Undo title for the selection when it is committed ("Move", "Paste", …).
    var selectionActionName = "Selection"
    /// The open text box, if any.
    var textBox: TextBox?

    /// Reports the pixel under the cursor, or `nil` when it leaves the canvas.
    var onCursorMove: ((PixelPoint?) -> Void)?
    var onZoomRequest: ((_ zoomIn: Bool, _ center: NSPoint) -> Void)?

    enum Drag {
        case stroke(Stroke)
        case marquee(start: PixelPoint, end: PixelPoint)
        case lasso([PixelPoint])
        case moveSelection(last: PixelPoint)
        case textBox(start: PixelPoint, end: PixelPoint)
    }

    /// A pencil, eraser or shape drag. `before` is the whole canvas as it was at mouse-down, used
    /// both to redraw rubber-band shapes and to build the undo snapshot once the drag ends.
    struct Stroke {
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
        lastTool = state.tool
        super.init(frame: NSRect(x: 0, y: 0, width: document.bitmap.width, height: document.bitmap.height))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        state.observe { [weak self] in self?.stateDidChange() }
        document.willWrite = { [weak self] in self?.finishInteractions() }
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

    /// Called for changes made by the document itself (undo, redo, revert). When the whole
    /// bitmap was swapped, a selection or text box would point at the old one, so drop them.
    func documentDidChangeBitmap(_ rect: PixelRect?) {
        if rect == nil {
            selection = nil
            drag = nil
            cancelText()
        }
        bitmapDidChange(rect)
    }

    /// Commits whatever is in progress (selection, text) so the bitmap is final.
    func finishInteractions() {
        commitText()
        commitSelection()
    }

    private func stateDidChange() {
        if state.tool != lastTool {
            if !state.tool.isSelection { commitSelection() }
            if state.tool != .text { commitText() }
            lastTool = state.tool
            window?.invalidateCursorRects(for: self)
        }
        if let selection, selection.isFloating, selection.transparentColor != state.selectionTransparentColor {
            bitmapDidChange(selection.setTransparentColor(state.selectionTransparentColor))
        }
        textBox?.apply(style: state.textStyle, color: state.primary, background: state.secondary)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if cachedImage == nil { cachedImage = document.bitmap.makeImage() }
        if let image = cachedImage {
            // Nearest-neighbor so zoomed-in pixels stay square.
            context.interpolationQuality = .none
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }
        if let outline = overlayPath() {
            drawMarchingAnts(outline, in: context)
        }
    }

    /// The dashed outline to show: the drag in progress, else the selection or text box.
    private func overlayPath() -> CGPath? {
        switch drag {
        case let .marquee(start, end), let .textBox(start, end):
            return CGPath(rect: PixelRect(enclosing: start, end).cgRect, transform: nil)
        case let .lasso(points):
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) })
            return path
        case .stroke, .moveSelection, nil:
            break
        }
        if let textBox {
            return CGPath(rect: textBox.textView.frame.insetBy(dx: -1, dy: -1), transform: nil)
        }
        guard let mask = selection?.mask else { return nil }
        guard let outline = mask.outline else { return CGPath(rect: mask.rect.cgRect, transform: nil) }
        let path = CGMutablePath()
        path.addLines(between: outline.map {
            CGPoint(x: CGFloat(mask.rect.x + $0.x) + 0.5, y: CGFloat(mask.rect.y + $0.y) + 0.5)
        })
        path.closeSubpath()
        return path
    }

    /// One screen pixel wide at any zoom: white underneath, black dashes on top.
    private func drawMarchingAnts(_ path: CGPath, in context: CGContext) {
        let unit = 1 / (enclosingScrollView?.magnification ?? 1)
        context.saveGState()
        context.setLineWidth(unit)
        context.addPath(path)
        context.setStrokeColor(.white)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(.black)
        context.setLineDash(phase: 0, lengths: [4 * unit, 4 * unit])
        context.strokePath()
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
        dragged(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        dragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        ended()
    }

    override func rightMouseUp(with event: NSEvent) {
        ended()
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
        guard drag == nil else { return }
        let p = pixel(for: event)
        let bitmap = document.bitmap

        // Clicking the canvas outside an open text box places the text, and does nothing else.
        if textBox != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        if !state.tool.isSelection { commitSelection() }

        switch state.tool {
        case .select, .freeFormSelect:
            beginSelectionDrag(at: p)
        case .text:
            drag = .textBox(start: p, end: p)
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
            let stroke = Stroke(tool: state.tool, usesSecondary: secondary, start: p, last: p, before: bitmap.copyPixels())
            drag = .stroke(stroke)
            if state.tool.shapeKind == nil { extend(stroke, to: p, constrained: false) }
        }
    }

    private func dragged(_ event: NSEvent) {
        let p = pixel(for: event)
        reportCursor(p)
        switch drag {
        case let .stroke(stroke):
            extend(stroke, to: p, constrained: event.modifierFlags.contains(.shift))
        case let .marquee(start, _):
            drag = .marquee(start: start, end: p)
            needsDisplay = true
        case var .lasso(points):
            if points.last != p { points.append(p) }
            drag = .lasso(points)
            needsDisplay = true
        case let .moveSelection(last):
            drag = .moveSelection(last: p)
            if let changed = selection?.move(dx: p.x - last.x, dy: p.y - last.y) { bitmapDidChange(changed) }
            needsDisplay = true
        case let .textBox(start, _):
            drag = .textBox(start: start, end: p)
            needsDisplay = true
        case nil:
            break
        }
    }

    private func ended() {
        let finished = drag
        drag = nil
        switch finished {
        case let .stroke(stroke):
            commit(before: stroke.before, rect: stroke.dirty, actionName: stroke.tool.title)
        case let .marquee(start, end):
            let rect = PixelRect(enclosing: start, end).intersection(document.bitmap.bounds)
            // A click without a drag just deselects.
            if start != end, !rect.isEmpty { select(SelectionMask(rect: rect)) }
        case let .lasso(points):
            if let mask = SelectionMask(polygon: points, within: document.bitmap.bounds) { select(mask) }
        case let .textBox(start, end):
            openTextBox(in: PixelRect(enclosing: start, end), dragged: start != end)
        case .moveSelection, nil:
            break
        }
        needsDisplay = true
    }

    // MARK: - Strokes

    private func extend(_ stroke: Stroke, to p: PixelPoint, constrained: Bool) {
        var stroke = stroke
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
        drag = .stroke(stroke)
        bitmapDidChange(changed)
    }

    func cancelStroke() {
        guard case let .stroke(stroke) = drag else { return }
        drag = nil
        document.bitmap.restore(stroke.dirty, from: stroke.before)
        bitmapDidChange(stroke.dirty)
    }

    func commit(before: [UInt32], rect: PixelRect, actionName: String) {
        let rect = rect.intersection(document.bitmap.bounds)
        guard !rect.isEmpty else { return }
        document.registerEdit(document.bitmap.snapshot(rect, from: before), actionName: actionName)
    }

    private func drawingColor(for stroke: Stroke) -> RGBA {
        stroke.usesSecondary ? state.secondary : state.primary
    }

    /// Left drag: outline in color 1, fill in color 2. Right drag swaps them.
    private func shapeStyle(for stroke: Stroke) -> ShapeStyle {
        let fill = stroke.usesSecondary ? state.primary : state.secondary
        return ShapeStyle(
            outline: drawingColor(for: stroke),
            fill: state.fillsShapes && stroke.tool != .line ? fill : nil,
            lineWidth: state.size
        )
    }

    // MARK: - Selection

    private func beginSelectionDrag(at p: PixelPoint) {
        if let selection, selection.mask.contains(p) {
            liftSelection()
            drag = .moveSelection(last: p)
            return
        }
        commitSelection()
        drag = state.tool == .select ? .marquee(start: p, end: p) : .lasso([p])
    }

    func select(_ mask: SelectionMask) {
        selection = SelectionSession(bitmap: document.bitmap, mask: mask)
        selectionActionName = "Move Selection"
        needsDisplay = true
    }

    /// Picks the selected pixels up so they can move; the hole is filled with color 2.
    func liftSelection() {
        guard let selection, !selection.isFloating else { return }
        selection.lift(background: state.secondary, transparent: state.selectionTransparentColor)
        bitmapDidChange(selection.mask.rect)
    }

    /// Deselects, recording everything the selection changed as one undo step.
    func commitSelection() {
        guard let selection else { return }
        self.selection = nil
        commit(before: selection.before, rect: selection.dirty, actionName: selectionActionName)
        needsDisplay = true
    }

    func nudgeSelection(dx: Int, dy: Int) {
        guard let selection else { return }
        liftSelection()
        bitmapDidChange(selection.move(dx: dx, dy: dy))
        needsDisplay = true
    }

    // MARK: - Text

    private func openTextBox(in rect: PixelRect, dragged: Bool) {
        let style = state.textStyle
        let lineHeight = NSLayoutManager().defaultLineHeight(for: style.font).rounded(.up)
        var frame = rect.cgRect
        if !dragged || frame.width < 16 {
            // A plain click makes a box wide enough for a few words.
            frame.size = CGSize(width: 200, height: lineHeight)
        }
        frame.size.height = max(frame.height, lineHeight)

        let box = TextBox(frame: frame, style: style, color: state.primary, background: state.secondary)
        box.onCancel = { [weak self] in self?.cancelText() }
        box.onChange = { [weak self] in self?.needsDisplay = true }
        addSubview(box.textView)
        textBox = box
        window?.makeFirstResponder(box.textView)
    }

    /// Draws the open text box into the bitmap as one undo step.
    func commitText() {
        guard let box = textBox else { return }
        textBox = nil
        box.textView.removeFromSuperview()
        needsDisplay = true
        window?.makeFirstResponder(self)
        guard !box.isEmpty else { return }

        let bitmap = document.bitmap
        let before = bitmap.copyPixels()
        let area = box.render(into: bitmap, opaque: state.textStyle.opaque, background: state.secondary)
        commit(before: before, rect: area, actionName: Tool.text.title)
        bitmapDidChange(area)
    }

    func cancelText() {
        guard let box = textBox else { return }
        textBox = nil
        box.textView.removeFromSuperview()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch event.keyCode {
        case 53: // Escape
            if case .stroke = drag { cancelStroke() } else { commitSelection() }
            return
        case 51 where selection != nil, 117 where selection != nil: // Delete, Forward Delete
            delete(nil)
            return
        case 123 where selection != nil: nudgeSelection(dx: -1, dy: 0); return
        case 124 where selection != nil: nudgeSelection(dx: 1, dy: 0); return
        case 125 where selection != nil: nudgeSelection(dx: 0, dy: 1); return
        case 126 where selection != nil: nudgeSelection(dx: 0, dy: -1); return
        default:
            break
        }
        if plain,
           let key = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.shortcut == key }) {
            state.tool = tool
            return
        }
        super.keyDown(with: event)
    }
}
