import AppKit
import PaintCore

/// Shows the document's bitmap at 1 unit per pixel (the enclosing scroll view does the zooming)
/// and turns mouse and keyboard input into tool operations.
final class CanvasView: NSView {
    /// Held strongly: views can outlive the document while a closed window is torn down, and
    /// the document lets go of its window controllers on close, so this makes no cycle.
    let document: CanvasDocument
    let state: EditorState
    private var cachedImage: CGImage?
    private var lastTool: Tool

    /// The mouse drag in progress, if any.
    var drag: Drag?
    /// The current selection, from when it is made until it is deselected.
    var selection: SelectionSession?
    /// Undo title for the selection when it is committed ("Move", "Paste", …).
    var selectionActionName = localized("Selection")
    /// The open text box, if any.
    var textBox: TextBox?
    /// A curve or polygon that takes several clicks to finish.
    var pendingShape: PendingShape?
    /// A drawn shape that can still be moved, resized and restyled.
    var activeShape: ActiveShape?
    /// The grab handle being dragged, if any.
    var handleDrag: HandleDrag?
    /// The handle chosen with Tab, which the arrow keys then move (Paint's keyboard control
    /// points); `nil` when the arrows move the whole selection or shape.
    var keyboardHandle: Handle? {
        didSet { onOverlayChange?() }
    }
    /// The canvas size shown while its handle is dragged.
    var canvasResizePreview: PixelRect?
    /// Set by a right-drag that makes a selection, which ends with the context menu.
    private var showsMenuAfterSelecting = false
    /// Where the selection was when the current drag of it began.
    private var selectionDragOrigin: PixelRect?
    /// Keeps the airbrush spraying while the mouse is held still.
    private var airbrushTimer: Timer?
    private var airbrushRandom = SystemRandomNumberGenerator()
    private var lastShapeKind: ShapeKind

    /// Paint's gridlines, shown at every zoom with a spacing that follows the zoom and the
    /// measuring unit (see `Gridlines`).
    var showsGridlines = false {
        didSet { needsDisplay = true }
    }

    /// Called after any change to what the canvas shows, for the thumbnail.
    var onDisplayChange: (() -> Void)?
    /// Called whenever the handles may need redrawing.
    var onOverlayChange: (() -> Void)?
    /// Called whenever what the status bar shows about the selection may have changed.
    var onStatusChange: (() -> Void)?
    /// Where the magnifier's preview rectangle follows the pointer.
    private var magnifierPoint: NSPoint?
    /// Scroll-wheel travel toward the next zoom step.
    private var wheelZoom: CGFloat = 0
    /// Reports the canvas size while its handle is dragged (`nil` when the drag ends).
    var onCanvasSizePreview: ((PixelRect?) -> Void)?

    /// Reports the pixel under the cursor, or `nil` when it leaves the canvas.
    var onCursorMove: ((PixelPoint?) -> Void)?
    var onZoomRequest: ((_ zoomIn: Bool, _ center: NSPoint) -> Void)?
    /// ⌘-scroll: one zoom step around the pointer.
    var onWheelZoom: ((_ zoomIn: Bool, _ center: NSPoint) -> Void)?

    enum Drag {
        case stroke(Stroke)
        case marquee(start: PixelPoint, end: PixelPoint)
        case lasso([PixelPoint])
        /// `smear` leaves a copy at every step (Paint's Shift+drag).
        case moveSelection(last: PixelPoint, smear: Bool)
        case textBox(start: PixelPoint, end: PixelPoint)
        /// Dragging a curve's control point (Paint's second and third clicks).
        case bend
        /// Dragging the newest polygon vertex.
        case polygonVertex
        /// Moving the active shape.
        case moveShape(last: PixelPoint)
        /// The color picker held down: the color under the pointer is shown until release.
        case pick(secondary: Bool)
    }

    /// A pencil, brush, eraser or shape drag. `before` is the whole canvas as it was at mouse-down, used
    /// both to redraw rubber-band shapes and to build the undo snapshot once the drag ends.
    struct Stroke {
        let tool: Tool
        /// For the shape tool, the shape being dragged out.
        let shapeKind: ShapeKind?
        let usesSecondary: Bool
        let start: PixelPoint
        var last: PixelPoint
        let before: [UInt32]
        var dirty = PixelRect.zero
        var shapeArea = PixelRect.zero
        /// A textured brush's footprint, composited over `before` as it grows.
        var layer: MediumLayer?
        /// The textured stroke's width at `last`, which pen pressure changes as it goes.
        var lastWidth = 0.0
        /// While Shift is held, the pencil and brushes keep to the direction they set off in:
        /// the point the lock began at and the 45° step it follows.
        var lock: (anchor: PixelPoint, direction: (dx: Int, dy: Int))?
    }

    init(document: CanvasDocument, state: EditorState) {
        self.document = document
        self.state = state
        lastTool = state.tool
        lastShapeKind = state.shapeKind
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

    override var needsDisplay: Bool {
        didSet {
            guard needsDisplay else { return }
            onOverlayChange?()
            onStatusChange?()
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        onOverlayChange?()
        onStatusChange?()
    }

    /// What the status bar's selection pane shows: a box being dragged out, the shape being
    /// drawn or edited, the text box, or the selection.
    var statusSelectionSize: PixelRect? {
        switch drag {
        case let .marquee(a, b), let .textBox(a, b):
            return PixelRect(enclosing: a, b)
        case let .lasso(points):
            return points.dropFirst().reduce(PixelRect(enclosing: points[0], points[0])) { $0.union(PixelRect(enclosing: $1, $1)) }
        case let .stroke(stroke) where stroke.shapeKind != nil:
            return PixelRect(enclosing: stroke.start, stroke.last)
        default:
            break
        }
        if let activeShape { return activeShape.box }
        if let textBox {
            let frame = textBox.textView.frame
            return PixelRect(x: Int(frame.minX), y: Int(frame.minY), width: Int(frame.width.rounded()), height: Int(frame.height.rounded()))
        }
        return selection?.mask.rect
    }

    /// Paint's magnifier preview: half the visible area, centered on the pointer and kept on
    /// the picture. Clicking zooms in to show it.
    func magnifierRect(at point: NSPoint) -> CGRect? {
        let visible = visibleRect
        guard visible.width > 0 else { return nil }
        let size = CGSize(width: min(visible.width / 2, bounds.width), height: min(visible.height / 2, bounds.height))
        let x = min(max(point.x - size.width / 2, 0), bounds.width - size.width)
        let y = min(max(point.y - size.height / 2, 0), bounds.height - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(), height: size.height.rounded())
    }

    func bitmapDidChange(_ rect: PixelRect?) {
        cachedImage = nil
        let size = NSSize(width: document.bitmap.width, height: document.bitmap.height)
        if frame.size != size { setFrameSize(size) }
        if let rect { setNeedsDisplay(rect.cgRect) } else { needsDisplay = true }
        onDisplayChange?()
    }

    /// Called for changes made by the document itself (undo, redo, revert). When the whole
    /// bitmap was swapped, a selection or text box would point at the old one, so drop them.
    func documentDidChangeBitmap(_ rect: PixelRect?) {
        if rect == nil {
            selection = nil
            pendingShape = nil
            activeShape = nil
            drag = nil
            handleDrag = nil
            canvasResizePreview = nil
            stopAirbrush()
            cancelText()
        }
        bitmapDidChange(rect)
    }

    /// Commits whatever is in progress (selection, text) so the bitmap is final.
    func finishInteractions() {
        finishPendingShape()
        commitActiveShape()
        commitText()
        commitSelection()
    }

    private func stateDidChange() {
        if state.tool != lastTool || state.shapeKind != lastShapeKind {
            finishPendingShape()
            commitActiveShape()
            lastShapeKind = state.shapeKind
        }
        // Outline, fill, size and colors restyle the active shape as they change.
        if activeShape != nil { redrawActiveShape() }
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
        drawGridlines(in: dirtyRect, context: context)
        if let outline = overlayPath() {
            drawMarchingAnts(outline, in: context)
        }
        if state.tool == .magnifier, let point = magnifierPoint, let rect = magnifierRect(at: point) {
            // A hollow inverted rectangle, as Paint draws it.
            context.saveGState()
            context.setBlendMode(.difference)
            context.setStrokeColor(.white)
            context.setLineWidth(1 / (enclosingScrollView?.magnification ?? 1))
            context.stroke(rect.insetBy(dx: 0.5 / (enclosingScrollView?.magnification ?? 1), dy: 0.5 / (enclosingScrollView?.magnification ?? 1)))
            context.restoreGState()
        }
    }

    /// Paint's `CImgWnd::DrawGrid`: one-screen-pixel dotted lines from the picture's top-left
    /// corner, every `Gridlines.spacing` units. From 400% they are opaque gray dots; below that,
    /// translucent dots laid over the picture.
    private func drawGridlines(in dirtyRect: NSRect, context: CGContext) {
        guard showsGridlines else { return }
        let zoom = enclosingScrollView?.magnification ?? 1
        let step = Gridlines.step(zoom: zoom, unit: Preferences.unit, dotsPerInch: document.dotsPerInch)
        guard step > 0 else { return }
        let area = dirtyRect.intersection(bounds)
        let dot = 1 / zoom
        let colors = Gridlines.colors(zoom: zoom)
        context.saveGState()
        context.setLineWidth(dot)
        // Two dashed passes, one for each color of the checkered dots.
        for (phase, color) in [(0, colors.0), (dot, colors.1)] {
            context.setStrokeColor(color)
            context.setLineDash(phase: phase, lengths: [dot, dot])
            var x = (Double(area.minX) / step).rounded(.down) * step
            while x <= Double(area.maxX) {
                context.move(to: CGPoint(x: x + dot / 2, y: 0))
                context.addLine(to: CGPoint(x: x + dot / 2, y: bounds.height))
                x += step
            }
            var y = (Double(area.minY) / step).rounded(.down) * step
            while y <= Double(area.maxY) {
                context.move(to: CGPoint(x: 0, y: y + dot / 2))
                context.addLine(to: CGPoint(x: bounds.width, y: y + dot / 2))
                y += step
            }
            context.strokePath()
        }
        context.restoreGState()
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
        case .stroke, .moveSelection, .bend, .polygonVertex, .moveShape, .pick, nil:
            break
        }
        if let textBox {
            return CGPath(rect: textBox.textView.frame.insetBy(dx: -1, dy: -1), transform: nil)
        }
        // Once made, every selection shows as its bounding box (Paint's tracker), free-form
        // ones included.
        guard let mask = selection?.mask else { return nil }
        return CGPath(rect: mask.rect.cgRect, transform: nil)
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
        // Paint's tracker border: 4 on, 4 off in the highlight color over the window color.
        context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
        context.setLineDash(phase: 0, lengths: [4 * unit, 4 * unit])
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        localized(format: "Canvas, %ld × %ld px", document.bitmap.width, document.bitmap.height)
    }

    override func accessibilityHelp() -> String? { state.tool.title }

    /// Tells VoiceOver users which tool a key press picked.
    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ToolCursors.cursor(for: state, magnification: enclosingScrollView?.magnification ?? 1))
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
        let p = pixel(for: event)
        reportCursor(p)
        hoverPendingShape(at: p)
        if state.tool == .magnifier {
            magnifierPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }
    }

    /// ⌘ with the scroll wheel steps the zoom, like Paint's Ctrl+wheel.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        wheelZoom += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 30 : event.scrollingDeltaY
        guard abs(wheelZoom) >= 1 else { return }
        onWheelZoom?(wheelZoom > 0, convert(event.locationInWindow, from: nil))
        wheelZoom = 0
    }

    override func mouseExited(with event: NSEvent) {
        onCursorMove?(nil)
        if magnifierPoint != nil {
            magnifierPoint = nil
            needsDisplay = true
        }
    }

    func pixel(for event: NSEvent) -> PixelPoint {
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
            if secondary, let selection, selection.mask.contains(p) {
                // Paint's right-click inside a selection opens its context menu.
                NSMenu.popUpContextMenu(selectionMenu(), with: event, for: self)
                return
            }
            beginSelectionDrag(at: p, modifiers: event.modifierFlags)
            if secondary { showsMenuAfterSelecting = true }
        case .text:
            drag = .textBox(start: p, end: p)
        case .picker:
            drag = .pick(secondary: secondary)
            pick(at: p, secondary: secondary)
        case .magnifier:
            onZoomRequest?(!secondary, convert(event.locationInWindow, from: nil))
        case .fill:
            let before = bitmap.copyPixels()
            let filled = bitmap.floodFill(at: p, with: secondary ? state.secondary : state.primary)
            commit(before: before, rect: filled, actionName: Tool.fill.title)
            bitmapDidChange(filled)
        case .shape where pendingShape != nil:
            continuePendingShape(at: p, clickCount: event.clickCount)
        case .shape where activeShape != nil:
            let reach = 8 / (enclosingScrollView?.magnification ?? 1)
            if let shape = activeShape, shape.grabs(p, reach: reach) {
                // The right button opens the shape's menu instead of dragging it.
                if secondary {
                    NSMenu.popUpContextMenu(shapeMenu(), with: event, for: self)
                } else {
                    drag = .moveShape(last: p)
                }
                return
            }
            // A press elsewhere draws the shape for good and starts a new one right there.
            commitActiveShape()
            fallthrough
        case .pencil, .brush, .eraser, .shape:
            var stroke = Stroke(
                tool: state.tool,
                shapeKind: state.tool == .shape ? state.shapeKind : nil,
                usesSecondary: secondary,
                start: p,
                last: p,
                before: bitmap.copyPixels()
            )
            if state.tool == .brush, let medium = state.brushKind.medium {
                // Each stroke gets its own texture variation, fixed by where it starts.
                let seed = UInt32(truncatingIfNeeded: p.x &* 73_856_093 ^ p.y &* 19_349_663)
                stroke.layer = MediumLayer(medium: medium, color: drawingColor(for: stroke), limit: bitmap.bounds, seed: seed)
                stroke.lastWidth = medium.strokeWidth(size: state.size, pressure: Self.pressure(of: event))
            }
            drag = .stroke(stroke)
            if stroke.shapeKind == nil { extend(stroke, to: p, constrained: false, pressure: Self.pressure(of: event)) }
            if state.tool == .brush, state.brushKind == .airbrush { startAirbrush() }
        }
    }

    private func dragged(_ event: NSEvent) {
        let p = pixel(for: event)
        reportCursor(p)
        switch drag {
        case let .stroke(stroke):
            extend(stroke, to: p, constrained: event.modifierFlags.contains(.shift), pressure: Self.pressure(of: event))
        case let .marquee(start, _):
            // Paint keeps the rubber band on the picture.
            let bounds = document.bitmap.bounds
            drag = .marquee(start: start, end: PixelPoint(x: min(max(p.x, 0), bounds.maxX - 1), y: min(max(p.y, 0), bounds.maxY - 1)))
            needsDisplay = true
        case var .lasso(points):
            if points.last != p { points.append(p) }
            drag = .lasso(points)
            needsDisplay = true
        case let .moveSelection(last, smear):
            guard let selection else { break }
            let step = selection.clampedOffset(dx: p.x - last.x, dy: p.y - last.y)
            drag = .moveSelection(last: PixelPoint(x: last.x + step.dx, y: last.y + step.dy), smear: smear)
            bitmapDidChange(selection.move(dx: step.dx, dy: step.dy))
            if smear { selection.dropCopy() }
            needsDisplay = true
        case let .textBox(start, _):
            drag = .textBox(start: start, end: p)
            needsDisplay = true
        case .bend, .polygonVertex:
            dragPendingShape(to: p)
        case let .moveShape(last):
            drag = .moveShape(last: p)
            moveActiveShape(dx: p.x - last.x, dy: p.y - last.y)
        case let .pick(secondary):
            pick(at: p, secondary: secondary)
        case nil:
            break
        }
    }

    /// Takes the color under `p` into Color 1 (or Color 2), live while the picker is dragged.
    private func pick(at p: PixelPoint, secondary: Bool) {
        let bitmap = document.bitmap
        guard bitmap.contains(p) else { return }
        if secondary { state.secondary = bitmap[p] } else { state.primary = bitmap[p] }
    }

    private func ended() {
        let finished = drag
        drag = nil
        stopAirbrush()
        switch finished {
        case let .stroke(stroke):
            if let kind = stroke.shapeKind, kind == .curve || kind == .polygon {
                if stroke.start == stroke.last {
                    // A click without a drag starts nothing (Paint discards it).
                    document.bitmap.restore(stroke.dirty, from: stroke.before)
                    bitmapDidChange(stroke.dirty)
                } else {
                    // The first drag only lays down a line; more clicks finish the shape.
                    beginPendingShape(from: stroke, kind: kind)
                }
            } else if let kind = stroke.shapeKind {
                activateShape(from: stroke, kind: kind)
            } else {
                commit(before: stroke.before, rect: stroke.dirty, actionName: stroke.shapeKind?.title ?? stroke.tool.title)
            }
        case let .marquee(start, end):
            let rect = PixelRect(enclosing: start, end).intersection(document.bitmap.bounds)
            // A click without a drag just deselects.
            if start != end, !rect.isEmpty { select(SelectionMask(rect: rect)) }
            showSelectionMenuIfRightDragged()
        case let .lasso(points):
            if let mask = SelectionMask(polygon: points, within: document.bitmap.bounds) { select(mask) }
            showSelectionMenuIfRightDragged()
        case let .textBox(start, end):
            openTextBox(in: PixelRect(enclosing: start, end), dragged: start != end)
        case .bend:
            releasePendingBend()
        case .pick:
            // Paint returns to the tool used before the picker.
            state.tool = state.previousTool
        case .moveSelection, .polygonVertex, .moveShape, nil:
            break
        }
        needsDisplay = true
    }

    // MARK: - Strokes

    /// Pen pressure from 0 to 1, or `nil` for a mouse or trackpad. Paint reads it from tablet
    /// packets only (`CRTSPacketHandler::ProcessPacket`).
    static func pressure(of event: NSEvent) -> Double? {
        event.subtype == .tabletPoint ? Double(event.pressure) : nil
    }

    func extend(_ stroke: Stroke, to p: PixelPoint, constrained: Bool, pressure: Double? = nil) {
        var stroke = stroke
        let bitmap = document.bitmap
        let changed: PixelRect
        var p = p

        // Pencil and brushes: Shift locks the stroke to the 45° direction it first moves in.
        if stroke.shapeKind == nil, stroke.tool == .pencil || stroke.tool == .brush {
            if !constrained {
                stroke.lock = nil
            } else if let lock = stroke.lock {
                p = Constraint.project(p, onto: lock.anchor, direction: lock.direction)
            } else if let direction = Constraint.direction(from: stroke.last, to: p) {
                stroke.lock = (stroke.last, direction)
                p = Constraint.project(p, onto: stroke.last, direction: direction)
            }
        }

        if let kind = stroke.shapeKind {
            // Rubber band: put back what the previous preview covered, then draw the shape again.
            bitmap.restore(stroke.shapeArea, from: stroke.before)
            var end = p
            if constrained {
                end = kind == .line
                    ? Constraint.snap45(from: stroke.start, to: p)
                    : Constraint.square(from: stroke.start, to: p)
            }
            let drawn = bitmap.drawShape(kind, from: stroke.start, to: end, style: shapeStyle(usesSecondary: stroke.usesSecondary, kind: kind))
            changed = stroke.shapeArea.union(drawn)
            stroke.shapeArea = drawn
            stroke.last = end
        } else if let layer = stroke.layer {
            // Only the textured brushes respond to pressure; Paint's other tools ignore it.
            let width = layer.medium.strokeWidth(size: state.size, pressure: pressure)
            changed = layer.addSegment(from: Self.center(of: stroke.last), width: stroke.lastWidth, to: Self.center(of: p), width: width)
            bitmap.composite(layer, in: changed, over: stroke.before)
            stroke.last = p
            stroke.lastWidth = width
        } else if stroke.tool == .brush {
            let color = drawingColor(for: stroke)
            switch state.brushKind {
            case .normal:
                changed = bitmap.drawRoundBrushLine(from: stroke.last, to: p, diameter: state.size, color: color)
            case .calligraphy45, .calligraphy135:
                changed = bitmap.drawCalligraphyLine(from: stroke.last, to: p, width: state.size, kind: state.brushKind, color: color)
            case .airbrush:
                changed = bitmap.spray(at: p, size: state.size, color: color, using: &airbrushRandom)
            case .oil, .crayon, .marker, .naturalPencil, .watercolor:
                changed = .zero // drawn through `stroke.layer` above
            }
            stroke.last = p
        } else {
            if stroke.tool == .eraser {
                // Left: paint Color 2. Right: turn only pixels of Color 1 into Color 2.
                changed = bitmap.drawSquareLine(
                    from: stroke.last, to: p, size: state.size, color: state.secondary,
                    replacing: stroke.usesSecondary ? state.primary : nil
                )
            } else {
                changed = bitmap.drawSquareLine(from: stroke.last, to: p, size: state.size, color: drawingColor(for: stroke))
            }
            stroke.last = p
        }

        stroke.dirty = stroke.dirty.union(changed)
        drag = .stroke(stroke)
        bitmapDidChange(changed)
    }

    func cancelStroke() {
        guard case let .stroke(stroke) = drag else { return }
        drag = nil
        stopAirbrush()
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

    private static func center(of p: PixelPoint) -> CGPoint {
        CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5)
    }

    /// Left drag: outline in color 1, fill in color 2. Right drag swaps them.
    func shapeStyle(usesSecondary: Bool, kind: ShapeKind) -> ShapeStyle {
        let outline = usesSecondary ? state.secondary : state.primary
        let fill = usesSecondary ? state.primary : state.secondary
        // Lines and curves always have an outline and never a fill.
        let outlinePaint = !kind.canFill && state.shapeOutline == .none ? .solid : state.shapeOutline
        let fillPaint = kind.canFill ? state.shapeFill : .none
        return ShapeStyle(
            outline: outlinePaint == .none ? nil : outline,
            fill: fillPaint == .none ? nil : fill,
            lineWidth: state.size,
            outlineMedium: outlinePaint.medium,
            fillMedium: fillPaint.medium
        )
    }

    // MARK: - Airbrush

    private func startAirbrush() {
        airbrushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, case let .stroke(stroke) = self.drag else { return }
            self.extend(stroke, to: stroke.last, constrained: false)
        }
    }

    private func stopAirbrush() {
        airbrushTimer?.invalidate()
        airbrushTimer = nil
    }

    // MARK: - Selection

    /// Pressing inside the selection drags it; ⌥ (Paint's Ctrl) drags a copy and leaves the
    /// original, ⇧ smears a trail of copies. Pressing outside starts a new selection.
    private func beginSelectionDrag(at p: PixelPoint, modifiers: NSEvent.ModifierFlags) {
        if let selection, selection.mask.contains(p) {
            if modifiers.contains(.option) || modifiers.contains(.shift) {
                if selection.isFloating {
                    selection.dropCopy()
                } else {
                    selection.lift(background: state.secondary, transparent: state.selectionTransparentColor, keepingOriginal: true)
                }
                if modifiers.contains(.option) { selectionActionName = localized("Copy Selection") }
            } else {
                liftSelection()
            }
            drag = .moveSelection(last: p, smear: modifiers.contains(.shift))
            selectionDragOrigin = selection.mask.rect
            return
        }
        commitSelection()
        drag = state.tool == .select ? .marquee(start: p, end: p) : .lasso([p])
    }

    /// Paint opens the selection's context menu after a right-drag makes one.
    private func showSelectionMenuIfRightDragged() {
        guard showsMenuAfterSelecting else { return }
        showsMenuAfterSelecting = false
        guard selection != nil, let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(selectionMenu(), with: event, for: self)
    }

    /// Paint's selection context menu.
    func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        add(localized("Cut"), #selector(cut(_:)))
        add(localized("Copy"), #selector(copy(_:)))
        add(localized("Paste"), #selector(paste(_:)))
        menu.addItem(.separator())
        add(localized("Crop"), #selector(crop(_:)))
        add(localized("Select All"), #selector(selectAll(_:)))
        add(localized("Invert Selection"), #selector(invertSelection(_:)))
        add(localized("Delete"), #selector(delete(_:)))
        menu.addItem(.separator())
        let rotate = NSMenuItem(title: localized("Rotate"), action: nil, keyEquivalent: "")
        rotate.submenu = rotateMenu()
        menu.addItem(rotate)
        add(localized("Resize"), #selector(resizeAndSkew(_:)))
        add(localized("Invert Color"), #selector(invertColor(_:)))
        return menu
    }

    /// Paint's Rotate drop-down, shared by the ribbon and the context menus.
    func rotateMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (localized("Rotate Right 90°"), #selector(rotateRight(_:))),
            (localized("Rotate Left 90°"), #selector(rotateLeft(_:))),
            (localized("Rotate 180°"), #selector(rotateHalfTurn(_:))),
            (localized("Flip Vertical"), #selector(flipVertical(_:))),
            (localized("Flip Horizontal"), #selector(flipHorizontal(_:))),
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }

    /// Paint's Invert Selection: selects everything the selection leaves out.
    @objc func invertSelection(_ sender: Any?) {
        let bounds = document.bitmap.bounds
        let current = selection?.mask
        commitSelection()
        guard let current else {
            selectAll(sender)
            return
        }
        if !state.tool.isSelection { state.tool = .select }
        if let inverted = current.inverted(within: bounds) { select(inverted) }
    }

    func select(_ mask: SelectionMask) {
        keyboardHandle = nil
        selection = SelectionSession(bitmap: document.bitmap, mask: mask)
        selectionActionName = localized("Move Selection")
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
        keyboardHandle = nil
        commit(before: selection.before, rect: selection.dirty, actionName: selectionActionName)
        needsDisplay = true
    }

    func nudgeSelection(dx: Int, dy: Int) {
        guard let selection else { return }
        liftSelection()
        let step = selection.clampedOffset(dx: dx, dy: dy)
        bitmapDidChange(selection.move(dx: step.dx, dy: step.dy))
        needsDisplay = true
    }

    // MARK: - Text

    private func openTextBox(in rect: PixelRect, dragged: Bool) {
        let style = state.textStyle
        let minimum = TextBox.minimumSize(for: style)
        var frame = rect.cgRect
        if !dragged {
            // A plain click makes Paint's smallest box.
            frame.size = minimum
        }
        frame.size.height = max(frame.height, NSLayoutManager().defaultLineHeight(for: style.font).rounded(.up))

        let box = TextBox(frame: frame, style: style, color: state.primary, background: state.secondary, maxBottom: CGFloat(document.bitmap.height))
        box.onCancel = { [weak self] in self?.cancelText() }
        box.onChange = { [weak self] in self?.needsDisplay = true }
        box.onSelectionStyle = { [weak self] style in self?.state.textStyle = style }
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
            if handleDrag != nil {
                cancelHandleDrag()
            } else if case .moveSelection = drag, let selection, let origin = selectionDragOrigin {
                // Esc during a drag puts the selection back where the drag began.
                drag = nil
                bitmapDidChange(selection.move(dx: origin.x - selection.mask.rect.x, dy: origin.y - selection.mask.rect.y))
                needsDisplay = true
            } else if case .stroke = drag {
                cancelStroke()
            } else if pendingShape != nil {
                cancelPendingShape()
            } else if activeShape != nil {
                discardActiveShape()
            } else {
                commitSelection()
            }
            return
        case 51 where selection != nil || activeShape != nil, 117 where selection != nil || activeShape != nil: // Delete, Forward Delete
            delete(nil)
            return
        // Return draws the active shape for good (Paint's Ctrl+Space, which macOS keeps for
        // switching input sources).
        case 36 where activeShape != nil, 76 where activeShape != nil:
            commitActiveShape()
            return
        // Tab and Shift+Tab pick a handle to move with the arrows.
        case 48 where activeShape != nil || selection != nil:
            cycleKeyboardHandle(backwards: event.modifierFlags.contains(.shift))
            return
        case 123...126 where keyboardHandle != nil && (activeShape != nil || selection != nil):
            let step = event.modifierFlags.contains(.shift) ? 2 : 1
            let (dx, dy) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][Int(event.keyCode)]!
            moveKeyboardHandle(dx: dx, dy: dy)
            return
        case 123 where activeShape != nil: moveActiveShape(dx: event.modifierFlags.contains(.shift) ? -2 : -1, dy: 0); return
        case 124 where activeShape != nil: moveActiveShape(dx: event.modifierFlags.contains(.shift) ? 2 : 1, dy: 0); return
        case 125 where activeShape != nil: moveActiveShape(dx: 0, dy: event.modifierFlags.contains(.shift) ? 2 : 1); return
        case 126 where activeShape != nil: moveActiveShape(dx: 0, dy: event.modifierFlags.contains(.shift) ? -2 : -1); return
        // Shift doubles the arrow keys' step, as in Paint.
        case 123 where selection != nil: nudgeSelection(dx: event.modifierFlags.contains(.shift) ? -2 : -1, dy: 0); return
        case 124 where selection != nil: nudgeSelection(dx: event.modifierFlags.contains(.shift) ? 2 : 1, dy: 0); return
        case 125 where selection != nil: nudgeSelection(dx: 0, dy: event.modifierFlags.contains(.shift) ? 2 : 1); return
        case 126 where selection != nil: nudgeSelection(dx: 0, dy: event.modifierFlags.contains(.shift) ? -2 : -1); return
        default:
            break
        }
        if plain,
           let key = event.charactersIgnoringModifiers?.lowercased().first,
           var tool = Tool.allCases.first(where: { $0.shortcut == key }) {
            // S switches between the two selection shapes once one is chosen; otherwise it
            // returns to the one used last.
            if tool == .select {
                switch state.tool {
                case .select: tool = .freeFormSelect
                case .freeFormSelect: tool = .select
                default: tool = state.lastSelectionTool
                }
            }
            state.tool = tool
            announce(tool.title)
            return
        }
        super.keyDown(with: event)
    }
}
