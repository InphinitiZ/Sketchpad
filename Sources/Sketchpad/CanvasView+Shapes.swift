import AppKit
import PaintCore

/// A curve or polygon between its first drag and its last click.
///
/// Curve: drag out a line, then drag twice to bend it; the first bend moves both control
/// points, the second only the second one. Polygon: drag the first side, then click each
/// further corner; double-click, or click within 10 pixels of the first corner, to close it.
struct PendingShape {
    let kind: ShapeKind
    let usesSecondary: Bool
    /// The canvas before the shape was started.
    let before: [UInt32]
    /// Curve: start, end, control 1, control 2. Polygon: the corners so far.
    var points: [PixelPoint]
    var bends = 0
    /// What the current preview covers, to be restored before the next one.
    var previewArea: PixelRect
    var dirty: PixelRect
}

/// A drawn shape that can still be changed (Paint's "modifying" state): moved, resized with its
/// handles, restyled, turned, flipped, inverted or deleted, until a click elsewhere, a tool
/// change or Return draws it for good.
struct ActiveShape {
    let kind: ShapeKind
    let usesSecondary: Bool
    /// The canvas before the shape was started.
    let before: [UInt32]
    /// Box shapes: the box. The others: the bounding box of `points`.
    var box: PixelRect
    /// Line, curve and polygon: their points (curve: start, end, control 1, control 2), at
    /// pixel centers, kept fractional so resizing back and forth does not drift.
    var points: [CGPoint]
    var orientation = ShapeOrientation.upright
    /// Invert Color on an active shape draws it in the inverse colors.
    var invertedColors = false
    var previewArea: PixelRect
    var dirty: PixelRect

    /// Paint keeps a box shape at least 8 pixels each way while its handles are dragged.
    static let minimumSize = 8

    var isBoxShape: Bool { kind.fitsBox }

    /// The handles: a line has one at each end, everything else eight around its box.
    var tracker: Tracker {
        guard kind == .line, points.count == 2 else {
            return Tracker(target: .shape, rect: box.cgRect, handles: Handle.allCases)
        }
        let a = points[0], b = points[1]
        let falling = (a.x <= b.x) == (a.y <= b.y)
        return Tracker(target: .shape, rect: box.cgRect, handles: falling ? [.topLeft, .bottomRight] : [.topRight, .bottomLeft])
    }

    static func boundingBox(of points: [CGPoint]) -> PixelRect {
        let xs = points.map { Int(($0.x - 0.5).rounded()) }, ys = points.map { Int(($0.y - 0.5).rounded()) }
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return PixelRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX + 1, height: (ys.max() ?? 0) - minY + 1)
    }

    /// Whether a press at `p` grabs the shape to move it: inside its box, or for a line,
    /// within `reach` pixels of it.
    func grabs(_ p: PixelPoint, reach: Double) -> Bool {
        let c = CGPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5)
        guard kind == .line, points.count == 2 else { return box.contains(p) }
        let a = points[0], b = points[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 > 0 ? min(max(((c.x - a.x) * dx + (c.y - a.y) * dy) / length2, 0), 1) : 0
        return hypot(c.x - (a.x + t * dx), c.y - (a.y + t * dy)) <= reach
    }

    mutating func move(dx: Int, dy: Int) {
        box = PixelRect(x: box.x + dx, y: box.y + dy, width: box.width, height: box.height)
        points = points.map { CGPoint(x: $0.x + CGFloat(dx), y: $0.y + CGFloat(dy)) }
    }

    /// Fits the shape to `newBox`, scaling its points from where they were in `oldBox`.
    mutating func fit(_ oldPoints: [CGPoint], from oldBox: PixelRect, to newBox: PixelRect) {
        box = newBox
        let sx = CGFloat(newBox.width) / CGFloat(max(oldBox.width, 1)), sy = CGFloat(newBox.height) / CGFloat(max(oldBox.height, 1))
        points = oldPoints.map {
            CGPoint(x: CGFloat(newBox.x) + ($0.x - CGFloat(oldBox.x)) * sx, y: CGFloat(newBox.y) + ($0.y - CGFloat(oldBox.y)) * sy)
        }
    }

    /// Applies Paint's Rotate and Flip commands to the shape, around the middle of its box.
    mutating func apply(_ transform: CanvasTransform) {
        if isBoxShape {
            orientation = orientation.applying(transform)
            if case let .rotate(rotation) = transform, rotation != .halfTurn {
                let center = box.cgRect
                box = PixelRect(
                    x: Int((center.midX - CGFloat(box.height) / 2).rounded()), y: Int((center.midY - CGFloat(box.width) / 2).rounded()),
                    width: box.height, height: box.width
                )
            }
            return
        }
        let frame = box.cgRect
        let center = CGPoint(x: frame.midX, y: frame.midY)
        points = points.map { p in
            let x = p.x - center.x, y = p.y - center.y
            switch transform {
            case .flipHorizontal: return CGPoint(x: center.x - x, y: p.y)
            case .flipVertical: return CGPoint(x: p.x, y: center.y - y)
            case .rotate(.clockwise): return CGPoint(x: center.x - y, y: center.y + x)
            case .rotate(.counterclockwise): return CGPoint(x: center.x + y, y: center.y - x)
            case .rotate(.halfTurn): return CGPoint(x: center.x - x, y: center.y - y)
            default: return p
            }
        }
        box = Self.boundingBox(of: points)
    }
}

extension CanvasView {
    // MARK: - Curve and polygon creation

    func beginPendingShape(from stroke: Stroke, kind: ShapeKind) {
        let points = kind == .curve
            ? [stroke.start, stroke.last, stroke.start, stroke.last]
            : [stroke.start, stroke.last]
        pendingShape = PendingShape(
            kind: kind,
            usesSecondary: stroke.usesSecondary,
            before: stroke.before,
            points: points,
            previewArea: stroke.shapeArea,
            dirty: stroke.dirty
        )
    }

    func continuePendingShape(at p: PixelPoint, clickCount: Int) {
        guard var pending = pendingShape else { return }
        if pending.kind == .curve {
            // A double-click ends the curve with the bends made so far.
            if clickCount >= 2 {
                finishPendingShape()
                return
            }
            drag = .bend
            dragPendingShape(to: p)
            return
        }
        let first = pending.points[0]
        if clickCount >= 2 || (abs(p.x - first.x) <= 10 && abs(p.y - first.y) <= 10) {
            finishPendingShape()
            return
        }
        pending.points.append(p)
        pendingShape = pending
        drag = .polygonVertex
        redrawPendingShape()
    }

    func dragPendingShape(to p: PixelPoint) {
        guard var pending = pendingShape else { return }
        if pending.kind == .curve {
            if pending.bends == 0 { pending.points[2] = p }
            pending.points[3] = p
        } else {
            pending.points[pending.points.count - 1] = p
        }
        pendingShape = pending
        redrawPendingShape()
    }

    func releasePendingBend() {
        guard var pending = pendingShape else { return }
        pending.bends += 1
        pendingShape = pending
        if pending.bends == 2 { finishPendingShape() }
    }

    /// Shows the polygon's next side following the cursor.
    func hoverPendingShape(at p: PixelPoint) {
        guard drag == nil, pendingShape?.kind == .polygon else { return }
        redrawPendingShape(hover: p)
    }

    /// Ends a curve or closes a polygon; it then stays editable like any other shape.
    func finishPendingShape() {
        guard pendingShape != nil else { return }
        redrawPendingShape(closed: true)
        guard let pending = pendingShape else { return }
        pendingShape = nil
        let points = pending.points.map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) }
        activeShape = ActiveShape(
            kind: pending.kind, usesSecondary: pending.usesSecondary, before: pending.before,
            box: ActiveShape.boundingBox(of: points), points: points,
            previewArea: pending.previewArea, dirty: pending.dirty
        )
        needsDisplay = true
    }

    func cancelPendingShape() {
        guard let pending = pendingShape else { return }
        pendingShape = nil
        document.bitmap.restore(pending.dirty, from: pending.before)
        bitmapDidChange(pending.dirty)
    }

    private func redrawPendingShape(hover: PixelPoint? = nil, closed: Bool = false) {
        guard var pending = pendingShape else { return }
        let bitmap = document.bitmap
        bitmap.restore(pending.previewArea, from: pending.before)
        let style = shapeStyle(usesSecondary: pending.usesSecondary, kind: pending.kind)
        let drawn: PixelRect
        if pending.kind == .curve {
            let p = pending.points
            drawn = bitmap.drawCurve(from: p[0], to: p[1], control1: p[2], control2: p[3], style: style)
        } else {
            drawn = bitmap.drawPolygon(pending.points + (hover.map { [$0] } ?? []), closed: closed, style: style)
        }
        let changed = pending.previewArea.union(drawn)
        pending.previewArea = drawn
        pending.dirty = pending.dirty.union(changed)
        pendingShape = pending
        bitmapDidChange(changed)
    }

    // MARK: - The active shape

    /// Turns a finished line or box-shape drag into an active shape, or drops it if it is empty.
    func activateShape(from stroke: Stroke, kind: ShapeKind) {
        guard stroke.start != stroke.last else {
            document.bitmap.restore(stroke.dirty, from: stroke.before)
            bitmapDidChange(stroke.dirty)
            return
        }
        let ends = [stroke.start, stroke.last].map { CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5) }
        let box = kind == .line ? ActiveShape.boundingBox(of: ends) : PixelRect(enclosing: stroke.start, stroke.last)
        activeShape = ActiveShape(
            kind: kind, usesSecondary: stroke.usesSecondary, before: stroke.before,
            box: box, points: kind == .line ? ends : [],
            previewArea: stroke.shapeArea, dirty: stroke.dirty
        )
        needsDisplay = true
    }

    /// Draws the active shape again, after it moved, changed size or the style changed.
    func redrawActiveShape() {
        guard var shape = activeShape else { return }
        let bitmap = document.bitmap
        bitmap.restore(shape.previewArea, from: shape.before)
        var style = shapeStyle(usesSecondary: shape.usesSecondary, kind: shape.kind)
        if shape.invertedColors {
            style.outline = style.outline.map { RGBA(packed: $0.packed ^ 0x00FF_FFFF) }
            style.fill = style.fill.map { RGBA(packed: $0.packed ^ 0x00FF_FFFF) }
        }
        let pixel = { (p: CGPoint) in PixelPoint(x: Int((p.x - 0.5).rounded()), y: Int((p.y - 0.5).rounded())) }
        let drawn: PixelRect
        switch shape.kind {
        case .line:
            drawn = bitmap.drawShape(.line, from: pixel(shape.points[0]), to: pixel(shape.points[1]), style: style)
        case .curve:
            let p = shape.points.map(pixel)
            drawn = bitmap.drawCurve(from: p[0], to: p[1], control1: p[2], control2: p[3], style: style)
        case .polygon:
            drawn = bitmap.drawPolygon(shape.points.map(pixel), closed: true, style: style)
        default:
            drawn = bitmap.drawShape(shape.kind, in: shape.box, orientation: shape.orientation, style: style)
        }
        let changed = shape.previewArea.union(drawn)
        shape.previewArea = drawn
        shape.dirty = shape.dirty.union(changed)
        activeShape = shape
        bitmapDidChange(changed)
    }

    /// Draws the active shape for good, as one undo step.
    func commitActiveShape() {
        guard let shape = activeShape else { return }
        activeShape = nil
        keyboardHandle = nil
        commit(before: shape.before, rect: shape.dirty, actionName: shape.kind.title)
        needsDisplay = true
    }

    /// Removes the active shape without drawing it (Paint's Esc and Delete).
    func discardActiveShape() {
        guard let shape = activeShape else { return }
        activeShape = nil
        keyboardHandle = nil
        document.bitmap.restore(shape.dirty, from: shape.before)
        bitmapDidChange(shape.dirty)
    }

    func moveActiveShape(dx: Int, dy: Int) {
        guard activeShape != nil, dx != 0 || dy != 0 else { return }
        activeShape?.move(dx: dx, dy: dy)
        redrawActiveShape()
    }

    /// Paint's context menu for an active shape.
    func shapeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: localized("Delete"), action: #selector(delete(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Paste"), action: #selector(paste(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let rotate = NSMenuItem(title: localized("Rotate"), action: nil, keyEquivalent: "")
        rotate.submenu = rotateMenu()
        menu.addItem(rotate)
        menu.addItem(NSMenuItem(title: localized("Invert Color"), action: #selector(invertColor(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for (title, outline) in [(localized("Outline"), true), (localized("Fill"), false)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for paint in ShapePaint.allCases {
                let choice = NSMenuItem(title: paint.title(forOutline: outline), action: #selector(chooseShapePaint(_:)), keyEquivalent: "")
                choice.representedObject = (outline, paint)
                choice.target = self
                choice.state = (outline ? state.shapeOutline : state.shapeFill) == paint ? .on : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            item.isEnabled = outline || activeShape?.kind.canFill == true
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseShapePaint(_ sender: NSMenuItem) {
        guard let (outline, paint) = sender.representedObject as? (Bool, ShapePaint) else { return }
        if outline { state.shapeOutline = paint } else { state.shapeFill = paint }
    }
}
