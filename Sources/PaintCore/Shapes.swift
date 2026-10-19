import CoreGraphics
import Foundation

/// Paint's 23 shapes, in its gallery order.
public enum ShapeKind: CaseIterable, Sendable {
    case line, curve, oval, rectangle, roundedRectangle, polygon
    case triangle, rightTriangle, diamond, pentagon, hexagon
    case rightArrow, leftArrow, upArrow, downArrow
    case fourPointStar, fivePointStar, sixPointStar
    case roundedRectangleCallout, ovalCallout, cloudCallout, heart, lightning

    /// Shapes that are drawn by dragging a box (everything but line, curve and polygon).
    public var fitsBox: Bool { self != .line && self != .curve && self != .polygon }

    public var canFill: Bool { self != .line && self != .curve }
}

public struct ShapeStyle: Sendable {
    /// `nil` is Paint's "No outline".
    public var outline: RGBA?
    /// `nil` is Paint's "No fill".
    public var fill: RGBA?
    public var lineWidth: Int
    /// On by default: `CDrawShapeOperation`'s constructor sets its antialias flag, so Paint's
    /// shapes have smooth edges even though its pencil does not.
    public var antialiased: Bool
    /// A textured outline or fill (Paint's Crayon, Marker, Oil, Natural pencil and Watercolor
    /// choices); `nil` is "Solid color". Marker fills, marker outlines and outlines under 4 px
    /// are drawn solid, as in Paint.
    public var outlineMedium: Medium?
    public var fillMedium: Medium?

    public init(
        outline: RGBA?, fill: RGBA? = nil, lineWidth: Int = 1, antialiased: Bool = true,
        outlineMedium: Medium? = nil, fillMedium: Medium? = nil
    ) {
        self.outline = outline
        self.fill = fill
        self.lineWidth = lineWidth
        self.antialiased = antialiased
        self.outlineMedium = outlineMedium
        self.fillMedium = fillMedium
    }

    /// The same outline without any fill, for lines, curves and open polygons.
    var outlineOnly: ShapeStyle {
        ShapeStyle(outline: outline, lineWidth: lineWidth, antialiased: antialiased, outlineMedium: outlineMedium)
    }
}

/// How a shape being edited has been turned and flipped (Paint's Rotate and Flip commands act
/// on the active shape). Quarter turns are clockwise and applied after the flips.
public struct ShapeOrientation: Equatable, Sendable {
    public var quarterTurns = 0
    public var flippedHorizontally = false
    public var flippedVertically = false

    public static let upright = ShapeOrientation()

    public init(quarterTurns: Int = 0, flippedHorizontally: Bool = false, flippedVertically: Bool = false) {
        self.quarterTurns = quarterTurns
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
    }

    /// The orientation after one more of Paint's Image > Rotate or Flip commands.
    public func applying(_ transform: CanvasTransform) -> ShapeOrientation {
        var result = self
        switch transform {
        case .rotate(.clockwise): result.quarterTurns += 1
        case .rotate(.counterclockwise): result.quarterTurns += 3
        case .rotate(.halfTurn): result.quarterTurns += 2
        // A flip after turning mirrors the turned shape: flip the other axis before the turn.
        case .flipHorizontal:
            if result.quarterTurns % 2 == 0 { result.flippedHorizontally.toggle() } else { result.flippedVertically.toggle() }
        case .flipVertical:
            if result.quarterTurns % 2 == 0 { result.flippedVertically.toggle() } else { result.flippedHorizontally.toggle() }
        default: break
        }
        result.quarterTurns %= 4
        return result
    }

    /// Maps a path drawn upright in a box centered on `center` to this orientation.
    func transform(around center: CGPoint) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: center.x, y: center.y)
        t = t.rotated(by: CGFloat(quarterTurns) * .pi / 2)
        t = t.scaledBy(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
        return t.translatedBy(x: -center.x, y: -center.y)
    }
}

extension Bitmap {
    /// Draws a box shape filling `box` (in canvas pixels), turned and flipped by `orientation`.
    @discardableResult
    public func drawShape(_ kind: ShapeKind, in box: PixelRect, orientation: ShapeOrientation, style: ShapeStyle) -> PixelRect {
        guard orientation != .upright else {
            return drawShape(kind, from: PixelPoint(x: box.x, y: box.y), to: PixelPoint(x: box.maxX - 1, y: box.maxY - 1), style: style)
        }
        // Lay the shape out upright in a box of the turned size, then turn it into place.
        let frame = box.cgRect
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let upright = orientation.quarterTurns % 2 == 0 ? frame : CGRect(x: center.x - frame.height / 2, y: center.y - frame.width / 2, width: frame.height, height: frame.width)
        let lineWidth = CGFloat(max(1, style.lineWidth))
        let inset = style.outline == nil ? 0 : lineWidth / 2
        let inner = upright.insetBy(dx: inset, dy: inset)
        var transform = orientation.transform(around: center)
        guard inner.width > 0, inner.height > 0, let path = ShapeGeometry.path(for: kind, in: inner)?.copy(using: &transform) else {
            guard let outline = style.outline, let whole = ShapeGeometry.path(for: kind, in: upright)?.copy(using: &transform) else { return .zero }
            let filled = ShapeStyle(outline: nil, fill: outline, antialiased: style.antialiased, fillMedium: style.outlineMedium)
            return render(whole, style: filled, closed: true)
        }
        return render(path, style: style, closed: true, miterJoins: kind == .rectangle)
    }

    /// Draws a line or a box shape spanning the pixels from `a` to `b` and returns the area
    /// it may have touched. Box shapes keep their outline inside the dragged box. The curve
    /// and polygon draw as a straight line here, which is how they start.
    @discardableResult
    public func drawShape(_ kind: ShapeKind, from a: PixelPoint, to b: PixelPoint, style: ShapeStyle) -> PixelRect {
        guard kind.fitsBox else {
            let path = CGMutablePath()
            path.move(to: center(a))
            path.addLine(to: center(b))
            return render(path, style: style, closed: false)
        }

        let lineWidth = CGFloat(max(1, style.lineWidth))
        let box = PixelRect(enclosing: a, b).cgRect
        let inset = style.outline == nil ? 0 : lineWidth / 2
        let inner = box.insetBy(dx: inset, dy: inset)
        guard inner.width > 0, inner.height > 0, let path = ShapeGeometry.path(for: kind, in: inner) else {
            // Box thinner than the outline: all of it is outline.
            guard let outline = style.outline, let whole = ShapeGeometry.path(for: kind, in: box) else { return .zero }
            let filled = ShapeStyle(outline: nil, fill: outline, antialiased: style.antialiased, fillMedium: style.outlineMedium)
            return render(whole, style: filled, closed: true)
        }
        return render(path, style: style, closed: true, miterJoins: kind == .rectangle)
    }

    /// Paint's curve: a line from `a` to `b` bent by two control points.
    @discardableResult
    public func drawCurve(from a: PixelPoint, to b: PixelPoint, control1: PixelPoint, control2: PixelPoint, style: ShapeStyle) -> PixelRect {
        let path = CGMutablePath()
        path.move(to: center(a))
        path.addCurve(to: center(b), control1: center(control1), control2: center(control2))
        return render(path, style: style.outlineOnly, closed: false)
    }

    /// Paint's polygon: connected vertices, filled once `closed`.
    @discardableResult
    public func drawPolygon(_ points: [PixelPoint], closed: Bool, style: ShapeStyle) -> PixelRect {
        guard let first = points.first else { return .zero }
        let path = CGMutablePath()
        path.move(to: center(first))
        for p in points.dropFirst() { path.addLine(to: center(p)) }
        if closed { path.closeSubpath() }
        return render(path, style: closed ? style : style.outlineOnly, closed: closed)
    }

    private func center(_ p: PixelPoint) -> CGPoint {
        CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5)
    }

    /// Fills then strokes `path`. Returns the area it may have touched.
    private func render(_ path: CGPath, style: ShapeStyle, closed: Bool, miterJoins: Bool = false) -> PixelRect {
        let lineWidth = CGFloat(max(1, style.lineWidth))
        let reach = path.boundingBoxOfPath.insetBy(dx: -lineWidth - 1, dy: -lineWidth - 1)
        let area = PixelRect(
            x: Int(reach.minX.rounded(.down)),
            y: Int(reach.minY.rounded(.down)),
            width: Int(reach.width.rounded(.up)) + 1,
            height: Int(reach.height.rounded(.up)) + 1
        ).intersection(self.bounds)

        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(style.antialiased)
        context.setLineWidth(lineWidth)
        context.setLineCap(closed ? .butt : .round)
        context.setLineJoin(miterJoins ? .miter : .round)

        if closed, let fill = style.fill {
            if let medium = style.fillMedium, medium.texturesFill {
                let layer = MediumLayer(medium: medium, color: fill, limit: area, seed: 1)
                composite(layer, in: layer.addFill(path, origin: path.boundingBoxOfPath.origin))
            } else {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        }
        if let outline = style.outline {
            if let medium = style.outlineMedium, medium.texturesOutline(width: style.lineWidth) {
                // Paint flattens the path and runs it through the brush engine.
                let layer = MediumLayer(medium: medium, color: outline, limit: area, seed: 2)
                var touched = PixelRect.zero
                for run in path.polylines() {
                    touched = touched.union(layer.addPolyline(run, width: Double(lineWidth)))
                }
                composite(layer, in: touched)
            } else {
                context.setStrokeColor(outline.cgColor)
                context.addPath(path)
                context.strokePath()
            }
        }
        return area
    }
}

/// Outlines of the box shapes. Proportions follow the Office AutoShapes that Paint's shape
/// gallery mirrors; points are given in a unit box (y down) and stretched to fit.
public enum ShapeGeometry {
    public static func path(for kind: ShapeKind, in r: CGRect) -> CGPath? {
        switch kind {
        case .line, .curve, .polygon:
            return nil
        case .rectangle:
            return CGPath(rect: r, transform: nil)
        case .oval:
            return CGPath(ellipseIn: r, transform: nil)
        case .roundedRectangle:
            let radius = min(r.width, r.height) * 0.2
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .triangle:
            return polygon([(0.5, 0), (1, 1), (0, 1)], in: r)
        case .rightTriangle:
            return polygon([(0, 0), (1, 1), (0, 1)], in: r)
        case .diamond:
            return polygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)], in: r)
        case .pentagon:
            return polygon(regular(sides: 5, startDegrees: -90), in: r)
        case .hexagon:
            return polygon(regular(sides: 6, startDegrees: 0), in: r)
        case .rightArrow:
            return polygon([(0, 0.25), (0.5, 0.25), (0.5, 0), (1, 0.5), (0.5, 1), (0.5, 0.75), (0, 0.75)], in: r)
        case .leftArrow:
            return polygon([(1, 0.25), (0.5, 0.25), (0.5, 0), (0, 0.5), (0.5, 1), (0.5, 0.75), (1, 0.75)], in: r)
        case .upArrow:
            return polygon([(0.25, 1), (0.25, 0.5), (0, 0.5), (0.5, 0), (1, 0.5), (0.75, 0.5), (0.75, 1)], in: r)
        case .downArrow:
            return polygon([(0.25, 0), (0.25, 0.5), (0, 0.5), (0.5, 1), (1, 0.5), (0.75, 0.5), (0.75, 0)], in: r)
        case .fourPointStar:
            return polygon(star(points: 4, innerRatio: 0.38), in: r)
        case .fivePointStar:
            return polygon(star(points: 5, innerRatio: 0.382), in: r)
        case .sixPointStar:
            return polygon(star(points: 6, innerRatio: 0.577), in: r)
        case .roundedRectangleCallout:
            return roundedRectangleCallout(in: r)
        case .ovalCallout:
            return ovalCallout(in: r)
        case .cloudCallout:
            return cloudCallout(in: r)
        case .heart:
            return heart(in: r)
        case .lightning:
            // Office's lightningBolt preset, in its 21600-unit space.
            let bolt: [(Double, Double)] = [
                (8458, 0), (0, 3923), (7564, 8416), (4993, 9720), (12197, 13904), (9987, 14934),
                (21600, 21600), (14768, 12911), (16558, 12016), (11030, 6840), (12575, 6120),
            ]
            return polygon(bolt.map { ($0.0 / 21600, $0.1 / 21600) }, in: r)
        }
    }

    private static func point(_ p: (Double, Double), in r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(p.0) * r.width, y: r.minY + CGFloat(p.1) * r.height)
    }

    private static func polygon(_ points: [(Double, Double)], in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { point($0, in: r) })
        path.closeSubpath()
        return path
    }

    /// A regular polygon stretched so its vertices touch all four sides of the box.
    private static func regular(sides: Int, startDegrees: Double) -> [(Double, Double)] {
        normalized((0..<sides).map { k in
            let angle = (startDegrees + 360 * Double(k) / Double(sides)) * .pi / 180
            return (cos(angle), sin(angle))
        })
    }

    private static func star(points: Int, innerRatio: Double) -> [(Double, Double)] {
        normalized((0..<points * 2).map { k in
            let radius = k.isMultiple(of: 2) ? 1 : innerRatio
            let angle = (-90 + 180 * Double(k) / Double(points)) * .pi / 180
            return (radius * cos(angle), radius * sin(angle))
        })
    }

    private static func normalized(_ points: [(Double, Double)]) -> [(Double, Double)] {
        let xs = points.map(\.0), ys = points.map(\.1)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return points.map { (($0.0 - minX) / (maxX - minX), ($0.1 - minY) / (maxY - minY)) }
    }

    /// Body in the top three quarters, tail pointing down and to the left.
    private static func roundedRectangleCallout(in r: CGRect) -> CGPath {
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.75)
        let radius = min(body.width, body.height) * 0.2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: body.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.1, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.2, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    private static func ovalCallout(in r: CGRect) -> CGPath {
        let center = CGPoint(x: r.midX, y: r.minY + r.height * 0.375)
        let rx = r.width / 2, ry = r.height * 0.375
        // Leave a gap between 100° and 130° (y down, so lower left) for the tail.
        let start = 130.0, end = 100.0 + 360
        let steps = 96
        let path = CGMutablePath()
        for i in 0...steps {
            let angle = (start + (end - start) * Double(i) / Double(steps)) * .pi / 180
            let p = CGPoint(x: center.x + rx * CGFloat(cos(angle)), y: center.y + ry * CGFloat(sin(angle)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.15, y: r.maxY))
        path.closeSubpath()
        return path
    }

    /// A scalloped oval with three shrinking thought bubbles trailing to the lower left.
    private static func cloudCallout(in r: CGRect) -> CGPath {
        // Scallops around a unit circle, then stretched to exactly fill the body area.
        let bumps = 10
        func onCircle(_ k: Int) -> CGPoint {
            let angle = 2 * Double.pi * Double(k) / Double(bumps)
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        let scallops = CGMutablePath()
        scallops.move(to: onCircle(0))
        for k in 0..<bumps {
            let a = onCircle(k), b = onCircle(k + 1)
            // Push the control point outward so each segment bulges into a scallop.
            let control = CGPoint(x: (a.x + b.x) / 2 * 1.45, y: (a.y + b.y) / 2 * 1.45)
            scallops.addQuadCurve(to: b, control: control)
        }
        scallops.closeSubpath()

        // The stroke's antialiased fringe at the scallop cusps reaches about a pixel past the
        // path, so keep the body that much inside the box.
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.72).insetBy(dx: 1, dy: 1)
        let extent = scallops.boundingBoxOfPath
        let fit = CGAffineTransform(translationX: body.minX, y: body.minY)
            .scaledBy(x: body.width / extent.width, y: body.height / extent.height)
            .translatedBy(x: -extent.minX, y: -extent.minY)
        let path = CGMutablePath()
        path.addPath(scallops, transform: fit)
        for (fx, fy, size) in [(0.28, 0.80, 0.10), (0.18, 0.90, 0.07), (0.10, 0.97, 0.045)] {
            let w = r.width * size, h = r.height * size
            path.addEllipse(in: CGRect(x: r.minX + r.width * fx - w / 2, y: r.minY + r.height * fy - h / 2, width: w, height: h))
        }
        return path
    }

    private static func heart(in r: CGRect) -> CGPath {
        func p(_ x: Double, _ y: Double) -> CGPoint { point((x, y), in: r) }
        let path = CGMutablePath()
        path.move(to: p(0.5, 0.25))
        path.addCurve(to: p(0, 0.3), control1: p(0.4, 0), control2: p(0, 0))
        path.addCurve(to: p(0.5, 1), control1: p(0, 0.6), control2: p(0.4, 0.8))
        path.addCurve(to: p(1, 0.3), control1: p(0.6, 0.8), control2: p(1, 0.6))
        path.addCurve(to: p(0.5, 0.25), control1: p(1, 0), control2: p(0.6, 0))
        path.closeSubpath()
        return path
    }
}
