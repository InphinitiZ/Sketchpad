import Foundation

/// Hard-edged pixel operations. Classic Paint draws pencil and eraser strokes and flood fills
/// without antialiasing, so these write pixels directly instead of going through Core Graphics.
public enum Raster {
    /// Visits every pixel on the Bresenham line from `a` to `b`, both endpoints included.
    public static func linePoints(from a: PixelPoint, to b: PixelPoint, _ body: (PixelPoint) -> Void) {
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            body(PixelPoint(x: x, y: y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x += sx
            }
            if e2 <= dx {
                err += dx
                y += sy
            }
        }
    }
}

extension Bitmap {
    /// Fills a `size`×`size` square around `p`, the footprint of the pencil and eraser.
    @discardableResult
    public func stampSquare(at p: PixelPoint, size: Int, color: RGBA, replacing target: RGBA? = nil) -> PixelRect {
        let half = size / 2
        let rect = PixelRect(x: p.x - half, y: p.y - half, width: size, height: size).intersection(bounds)
        guard !rect.isEmpty else { return .zero }
        let value = color.packed
        let only = target?.packed
        for y in rect.y..<rect.maxY {
            let row = y * width
            for x in rect.x..<rect.maxX where only == nil || storage[row + x] == only {
                storage[row + x] = value
            }
        }
        return rect
    }

    /// Drags a square stamp along the line from `a` to `b`. With `target`, only pixels of exactly
    /// that color are painted: the eraser's right-button color replacement, which turns Color 1
    /// into Color 2 and leaves everything else alone.
    @discardableResult
    public func drawSquareLine(from a: PixelPoint, to b: PixelPoint, size: Int, color: RGBA, replacing target: RGBA? = nil) -> PixelRect {
        var changed = PixelRect.zero
        Raster.linePoints(from: a, to: b) { p in
            changed = changed.union(stampSquare(at: p, size: size, color: color, replacing: target))
        }
        return changed
    }

    /// Scanline flood fill of the 4-connected region whose color exactly matches the pixel at `seed`.
    ///
    /// Paint has no tolerance setting: `CFloodTool::OnStartDrag` reads the seed with `GetPixel`
    /// and calls `ExtFloodFill(…, FLOODFILLSURFACE)`.
    @discardableResult
    public func floodFill(at seed: PixelPoint, with color: RGBA) -> PixelRect {
        guard contains(seed) else { return .zero }
        let target = storage[seed.y * width + seed.x]
        let replacement = color.packed
        guard target != replacement else { return .zero }

        var minX = seed.x, maxX = seed.x, minY = seed.y, maxY = seed.y
        var stack = [seed]
        while let p = stack.popLast() {
            let row = p.y * width
            guard storage[row + p.x] == target else { continue }
            var left = p.x
            while left > 0 && storage[row + left - 1] == target { left -= 1 }
            var right = p.x
            while right < width - 1 && storage[row + right + 1] == target { right += 1 }
            for x in left...right { storage[row + x] = replacement }

            minX = min(minX, left)
            maxX = max(maxX, right)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)

            for y in [p.y - 1, p.y + 1] where y >= 0 && y < height {
                let neighborRow = y * width
                var x = left
                while x <= right {
                    if storage[neighborRow + x] == target {
                        stack.append(PixelPoint(x: x, y: y))
                        while x <= right && storage[neighborRow + x] == target { x += 1 }
                    } else {
                        x += 1
                    }
                }
            }
        }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Shift-key constraints for the line and shape tools.
public enum Constraint {
    /// The pencil's Shift lock: the direction from `anchor` to `p` rounded to a multiple of 45°,
    /// as a step of -1, 0 or 1 on each axis (`CPencilTool::AdjustPointsForConstraint`).
    public static func direction(from anchor: PixelPoint, to p: PixelPoint) -> (dx: Int, dy: Int)? {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        guard dx != 0 || dy != 0 else { return nil }
        let octant = Int(((atan2(Double(dy), Double(dx)) * 180 / .pi + 22.5 + 360).truncatingRemainder(dividingBy: 360) / 45).rounded(.down))
        let steps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        return steps[octant % 8]
    }

    /// `p` moved onto the line through `anchor` along `direction`.
    public static func project(_ p: PixelPoint, onto anchor: PixelPoint, direction: (dx: Int, dy: Int)) -> PixelPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        switch (direction.dx, direction.dy) {
        case (_, 0): return PixelPoint(x: p.x, y: anchor.y)
        case (0, _): return PixelPoint(x: anchor.x, y: p.y)
        default:
            // Diagonal: equal steps on both axes.
            let t = (dx * direction.dx + dy * direction.dy) / 2
            return PixelPoint(x: anchor.x + t * direction.dx, y: anchor.y + t * direction.dy)
        }
    }

    /// Snaps `b` so the segment from `a` is horizontal, vertical or at 45°: within 22.5° of an
    /// axis it lies on the axis (Paint compares the slope with tan 22.5° and tan 67.5°).
    public static func snap45(from a: PixelPoint, to b: PixelPoint) -> PixelPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let adx = Double(abs(dx)), ady = Double(abs(dy))
        if ady < adx * 0.414 { return PixelPoint(x: b.x, y: a.y) }
        if ady > adx * 2.414 { return PixelPoint(x: a.x, y: b.y) }
        return square(from: a, to: b)
    }

    /// Moves `b` so the box from `a` is square, keeping the drag direction. The side is the
    /// shorter of the two drag distances, as in Paint.
    public static func square(from a: PixelPoint, to b: PixelPoint) -> PixelPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let side = min(abs(dx), abs(dy))
        return PixelPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }
}
