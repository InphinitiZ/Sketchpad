import CoreGraphics

/// Paint's brush gallery, in its order.
public enum BrushKind: CaseIterable, Sendable {
    case normal
    /// Nib slanted like "/" (Paint's "Calligraphy brush 1", 45°).
    case calligraphy45
    /// Nib slanted like "\" (Paint's "Calligraphy brush 2", 135°).
    case calligraphy135
    case airbrush
    case oil, crayon, marker, naturalPencil, watercolor

    /// The textured brushes' medium; `nil` for the plain ones.
    public var medium: Medium? {
        switch self {
        case .oil: .oil
        case .crayon: .crayon
        case .marker: .marker
        case .naturalPencil: .naturalPencil
        case .watercolor: .watercolor
        case .normal, .calligraphy45, .calligraphy135, .airbrush: nil
        }
    }
}

public enum Airbrush {
    /// Dots placed per burst (`CAirBrushTool::OnDrag` loops until it has drawn 10).
    public static let dotsPerBurst = 10

    /// The spray circle's diameter: the size rounded up to even, at least 4.
    public static func diameter(forSize size: Int) -> Int {
        max(4, (size + 1) & ~1)
    }
}

extension Bitmap {
    /// The round brush's footprint, after `PGSHelper::FillCustomCircleBitmap`: a pixel is in
    /// if its distance from the center is within the radius. Odd sizes center on a pixel
    /// (radius (w − ½)/2); even sizes center between pixels (radius w/2). Row-major, w×w.
    public static func circleMask(diameter w: Int) -> [Bool] {
        let center = w % 2 == 1 ? Double(w / 2) : Double(w - 1) / 2
        let radius = w % 2 == 1 ? (Double(w) - 0.5) / 2 : Double(w) / 2
        return (0..<w * w).map { i in
            let dx = Double(i % w) - center, dy = Double(i / w) - center
            return (dx * dx + dy * dy).squareRoot() <= radius
        }
    }

    @discardableResult
    public func stampCircle(at p: PixelPoint, diameter: Int, color: RGBA) -> PixelRect {
        let mask = Self.circleMask(diameter: diameter)
        let origin = PixelPoint(x: p.x - (diameter - 1) / 2, y: p.y - (diameter - 1) / 2)
        let area = PixelRect(x: origin.x, y: origin.y, width: diameter, height: diameter).intersection(bounds)
        guard !area.isEmpty else { return .zero }
        let value = color.packed
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX where mask[(y - origin.y) * diameter + (x - origin.x)] {
                storage[y * width + x] = value
            }
        }
        return area
    }

    /// The normal brush: round stamps along the line, so the stroke is a hard-edged capsule.
    @discardableResult
    public func drawRoundBrushLine(from a: PixelPoint, to b: PixelPoint, diameter: Int, color: RGBA) -> PixelRect {
        var changed = PixelRect.zero
        Raster.linePoints(from: a, to: b) { changed = changed.union(stampCircle(at: $0, diameter: diameter, color: color)) }
        return changed
    }

    /// A calligraphy stroke: the diagonal nib swept from `a` to `b`. Stamping the nib alone
    /// would leave holes when moving across its slant, so the swept parallelogram is filled too.
    @discardableResult
    public func drawCalligraphyLine(from a: PixelPoint, to b: PixelPoint, width: Int, kind: BrushKind, color: RGBA) -> PixelRect {
        precondition(kind == .calligraphy45 || kind == .calligraphy135)
        let half = (width - 1) / 2
        // Screen y points down, so "/" runs toward negative y.
        let slope = kind == .calligraphy45 ? -1 : 1
        let start = PixelPoint(x: -half, y: -half * slope)
        let end = PixelPoint(x: width - 1 - half, y: (width - 1 - half) * slope)

        context.saveGState()
        context.setShouldAntialias(false)
        context.setFillColor(color.cgColor)
        let corners = [(a, start), (a, end), (b, end), (b, start)].map { p, offset in
            CGPoint(x: CGFloat(p.x + offset.x) + 0.5, y: CGFloat(p.y + offset.y) + 0.5)
        }
        context.addLines(between: corners)
        context.closePath()
        context.fillPath()
        context.restoreGState()

        var changed = PixelRect.zero
        Raster.linePoints(from: a, to: b) { p in
            Raster.linePoints(from: PixelPoint(x: p.x + start.x, y: p.y + start.y), to: PixelPoint(x: p.x + end.x, y: p.y + end.y)) { q in
                changed = changed.union(stampSquare(at: q, size: 1, color: color))
            }
        }
        let swept = PixelRect(enclosing: a, b).insetBy(dx: -width, dy: -width)
        return changed.union(swept.intersection(bounds))
    }

    /// One airbrush burst, after `CAirBrushTool::OnDrag`: offsets in [−r, r] from `rand`,
    /// rejected outside the circle, until `Airbrush.dotsPerBurst` single pixels are placed.
    @discardableResult
    public func spray<Generator: RandomNumberGenerator>(
        at p: PixelPoint, size: Int, color: RGBA, using generator: inout Generator
    ) -> PixelRect {
        let diameter = Airbrush.diameter(forSize: size)
        let radius = diameter / 2
        var placed = 0
        var changed = PixelRect.zero
        while placed < Airbrush.dotsPerBurst {
            let dx = Int.random(in: 0...diameter, using: &generator) - radius
            let dy = Int.random(in: 0...diameter, using: &generator) - radius
            guard dx * dx + dy * dy <= radius * radius else { continue }
            placed += 1
            changed = changed.union(stampSquare(at: PixelPoint(x: p.x + dx, y: p.y + dy), size: 1, color: color))
        }
        return changed
    }
}
