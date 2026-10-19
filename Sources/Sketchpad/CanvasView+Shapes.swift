import AppKit
import PaintCore

/// A curve or polygon between its first drag and its last click.
///
/// Curve: drag out a line, then drag twice to bend it; the first bend moves both control
/// points, the second only the second one. Polygon: drag the first side, then click each
/// further corner; double-click, or click the first corner, to close it.
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

extension CanvasView {
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
            drag = .bend
            dragPendingShape(to: p)
            return
        }
        let first = pending.points[0]
        if clickCount >= 2 || (abs(p.x - first.x) <= 3 && abs(p.y - first.y) <= 3) {
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

    /// Draws the shape for good (closing a polygon) as one undo step.
    func finishPendingShape() {
        guard pendingShape != nil else { return }
        redrawPendingShape(closed: true)
        guard let pending = pendingShape else { return }
        pendingShape = nil
        commit(before: pending.before, rect: pending.dirty, actionName: pending.kind.title)
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
}
