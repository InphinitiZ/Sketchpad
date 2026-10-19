import AppKit
import PaintCore

/// A grab handle being dragged.
struct HandleDrag {
    let tracker: Tracker
    let handle: Handle
    /// Where the drag started, in canvas coordinates.
    let start: CGPoint
    /// The rectangle being reshaped, as it was at the start.
    var startRect: PixelRect
    /// A selection's lifted pixels at the start; every step stretches these afresh.
    let source: (grid: PixelGrid, mask: SelectionMask)?
    /// An active shape's points at the start, and for a line the end being dragged.
    var shapePoints: [CGPoint] = []
    var lineEnd: Int?
    /// Dragging the text box by its border moves it instead of resizing it.
    var movesWhole = false
}

extension CanvasView {
    /// The handles to show: the canvas always has its three, and the selection or text box
    /// has eight while it exists.
    var trackers: [Tracker] {
        let canvas = canvasResizePreview ?? document.bitmap.bounds
        var list = [Tracker(target: .canvas, rect: canvas.cgRect, handles: Handle.canvas)]
        if let textBox {
            list.append(Tracker(target: .textBox, rect: textBox.textView.frame, handles: Handle.allCases))
        } else if let activeShape {
            list.append(activeShape.tracker)
        } else if let selection, !isMakingSelection {
            list.append(Tracker(target: .selection, rect: selection.mask.rect.cgRect, handles: Handle.allCases))
        }
        return list
    }

    var handleDragTarget: TrackerTarget? { handleDrag?.tracker.target }

    private var isMakingSelection: Bool {
        switch drag {
        case .marquee, .lasso: true
        default: false
        }
    }

    func beginHandleDrag(_ tracker: Tracker, _ handle: Handle, at point: CGPoint) {
        guard drag == nil, handleDrag == nil else { return }
        window?.makeFirstResponder(self)
        let rect = PixelRect(
            x: Int(tracker.rect.minX.rounded()), y: Int(tracker.rect.minY.rounded()),
            width: Int(tracker.rect.width.rounded()), height: Int(tracker.rect.height.rounded())
        )
        var source: (grid: PixelGrid, mask: SelectionMask)?
        switch tracker.target {
        case .selection:
            liftSelection()
            source = selection?.floatingContent
        case .canvas:
            // Resizing the canvas places whatever is in progress first.
            finishInteractions()
        case .textBox, .shape:
            break
        }
        handleDrag = HandleDrag(tracker: tracker, handle: handle, start: point, startRect: rect, source: source)
        if tracker.target == .shape, let shape = activeShape {
            handleDrag?.startRect = shape.box
            handleDrag?.shapePoints = shape.points
            if shape.kind == .line, shape.points.count == 2 {
                // The end nearest the grabbed corner.
                let corner = CGPoint(x: tracker.rect.minX + tracker.rect.width * handle.anchor.x, y: tracker.rect.minY + tracker.rect.height * handle.anchor.y)
                let distances = shape.points.map { hypot($0.x - corner.x, $0.y - corner.y) }
                handleDrag?.lineEnd = distances[0] <= distances[1] ? 0 : 1
            }
        }
    }

    /// Tab's order: clockwise from the top-left corner.
    static let handleCycle: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    func cycleKeyboardHandle(backwards: Bool) {
        let cycle = Self.handleCycle
        guard let current = keyboardHandle, let index = cycle.firstIndex(of: current) else {
            keyboardHandle = backwards ? cycle.last : cycle.first
            return
        }
        keyboardHandle = cycle[(index + (backwards ? cycle.count - 1 : 1)) % cycle.count]
    }

    /// Moves the Tab-chosen handle; side handles move only across their side.
    func moveKeyboardHandle(dx: Int, dy: Int) {
        guard let handle = keyboardHandle else { return }
        let dx = handle.movesLeft || handle.movesRight ? dx : 0
        let dy = handle.movesTop || handle.movesBottom ? dy : 0
        guard dx != 0 || dy != 0 else { return }
        if var shape = activeShape {
            let box = handle.resizing(shape.box, dx: dx, dy: dy, minimum: ActiveShape.minimumSize)
            shape.fit(shape.points, from: shape.box, to: box)
            activeShape = shape
            redrawActiveShape()
        } else if let selection {
            liftSelection()
            guard let source = selection.floatingContent else { return }
            bitmapDidChange(selection.stretch(source, to: handle.resizing(selection.mask.rect, dx: dx, dy: dy), background: state.secondary))
            if selectionActionName == localized("Move Selection") { selectionActionName = localized("Resize") }
        }
        needsDisplay = true
    }

    /// Paint's text box moves when dragged by its border.
    func beginTextBoxMove(at point: CGPoint) {
        guard let textBox, drag == nil, handleDrag == nil else { return }
        let frame = textBox.textView.frame
        let tracker = Tracker(target: .textBox, rect: frame, handles: Handle.allCases)
        handleDrag = HandleDrag(
            tracker: tracker, handle: .topLeft, start: point,
            startRect: PixelRect(x: Int(frame.minX.rounded()), y: Int(frame.minY.rounded()), width: Int(frame.width.rounded()), height: Int(frame.height.rounded())),
            source: nil, movesWhole: true
        )
    }

    func dragHandle(to point: CGPoint) {
        guard let handleDrag else { return }
        let dx = Int((point.x - handleDrag.start.x).rounded())
        let dy = Int((point.y - handleDrag.start.y).rounded())
        let rect = handleDrag.handle.resizing(handleDrag.startRect, dx: dx, dy: dy)
        switch handleDrag.tracker.target {
        case .selection:
            guard let selection, let source = handleDrag.source else { return }
            bitmapDidChange(selection.stretch(source, to: rect, background: state.secondary))
            if selectionActionName == localized("Move Selection") { selectionActionName = localized("Resize") }
        case .canvas:
            canvasResizePreview = PixelRect(x: 0, y: 0, width: rect.maxX, height: rect.maxY)
            onCanvasSizePreview?(canvasResizePreview)
        case .textBox where handleDrag.movesWhole:
            let start = handleDrag.startRect
            textBox?.setFrame(CGRect(x: start.x + dx, y: start.y + dy, width: start.width, height: start.height))
        case .textBox:
            textBox?.setFrame(rect.cgRect)
        case .shape:
            guard var shape = activeShape else { return }
            if let end = handleDrag.lineEnd {
                // A line's handles move its ends freely.
                shape.points[end] = CGPoint(x: handleDrag.shapePoints[end].x + CGFloat(dx), y: handleDrag.shapePoints[end].y + CGFloat(dy))
                shape.box = ActiveShape.boundingBox(of: shape.points)
            } else {
                let box = handleDrag.handle.resizing(handleDrag.startRect, dx: dx, dy: dy, minimum: ActiveShape.minimumSize)
                shape.fit(handleDrag.shapePoints, from: handleDrag.startRect, to: box)
            }
            activeShape = shape
            redrawActiveShape()
        }
        needsDisplay = true
    }

    /// Esc during a handle drag puts things back as they were when it started.
    func cancelHandleDrag() {
        guard let cancelled = handleDrag else { return }
        handleDrag = nil
        switch cancelled.tracker.target {
        case .canvas:
            canvasResizePreview = nil
            onCanvasSizePreview?(nil)
        case .selection:
            if let selection, let source = cancelled.source {
                bitmapDidChange(selection.stretch(source, to: source.mask.rect, background: state.secondary))
            }
        case .shape:
            if var shape = activeShape {
                if cancelled.lineEnd != nil {
                    shape.points = cancelled.shapePoints
                    shape.box = ActiveShape.boundingBox(of: shape.points)
                } else {
                    shape.fit(cancelled.shapePoints, from: cancelled.startRect, to: cancelled.startRect)
                }
                activeShape = shape
                redrawActiveShape()
            }
        case .textBox:
            textBox?.setFrame(cancelled.tracker.rect)
        }
        needsDisplay = true
    }

    /// Paint's Ctrl+Plus and Ctrl+Minus (⌘] and ⌘[ here, as ⌘+ and ⌘− zoom on the Mac): with a
    /// selection they double or halve it, otherwise they step the tool's size.
    @objc func largerSize(_ sender: Any?) {
        stepSize(up: true)
    }

    @objc func smallerSize(_ sender: Any?) {
        stepSize(up: false)
    }

    private func stepSize(up: Bool) {
        if let selection {
            liftSelection()
            guard let source = selection.floatingContent else { return }
            let rect = selection.mask.rect
            let width = up ? rect.width * 2 : max(1, rect.width / 2)
            let height = up ? rect.height * 2 : max(1, rect.height / 2)
            bitmapDidChange(selection.stretch(source, to: PixelRect(x: rect.x, y: rect.y, width: width, height: height), background: state.secondary))
            if selectionActionName == localized("Move Selection") { selectionActionName = localized("Resize") }
            needsDisplay = true
            return
        }
        let options = state.sizeOptions
        guard let index = options.firstIndex(of: state.size) ?? options.firstIndex(where: { $0 >= state.size }) else { return }
        let next = min(max(index + (up ? 1 : -1), 0), options.count - 1)
        state.size = options[next]
    }

    func endHandleDrag() {
        guard let finished = handleDrag else { return }
        handleDrag = nil
        if finished.tracker.target == .canvas, let size = canvasResizePreview {
            canvasResizePreview = nil
            onCanvasSizePreview?(nil)
            resizeCanvas(width: size.width, height: size.height)
        }
        needsDisplay = true
    }

    /// Changes the canvas size, keeping the picture at the top-left and filling new area with
    /// color 2, as one undo step.
    func resizeCanvas(width: Int, height: Int) {
        let bitmap = document.bitmap
        guard width != bitmap.width || height != bitmap.height else { return }
        let grid = bitmap.grid.withCanvasSize(width: width, height: height, background: state.secondary.packed)
        document.replaceBitmap(Bitmap(grid: grid), actionName: localized("Resize Canvas"))
    }
}
