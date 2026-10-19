import CoreGraphics

public enum ShapeKind: Sendable {
    case line
    case rectangle
    case ellipse
}

public struct ShapeStyle: Sendable {
    public var outline: RGBA
    public var fill: RGBA?
    public var lineWidth: Int
    /// On by default: `CDrawShapeOperation`'s constructor sets its antialias flag, so Paint's
    /// shapes have smooth edges even though its pencil does not.
    public var antialiased: Bool

    public init(outline: RGBA, fill: RGBA? = nil, lineWidth: Int = 1, antialiased: Bool = true) {
        self.outline = outline
        self.fill = fill
        self.lineWidth = lineWidth
        self.antialiased = antialiased
    }
}

extension Bitmap {
    /// Draws a shape spanning the pixels from `a` to `b` and returns the area it may have touched.
    ///
    /// Rectangles and ellipses keep their outline inside the dragged box.
    @discardableResult
    public func drawShape(_ kind: ShapeKind, from a: PixelPoint, to b: PixelPoint, style: ShapeStyle) -> PixelRect {
        let lineWidth = CGFloat(max(1, style.lineWidth))
        let box = PixelRect(enclosing: a, b).cgRect

        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(style.antialiased)
        context.setStrokeColor(style.outline.cgColor)
        context.setLineWidth(lineWidth)

        switch kind {
        case .line:
            context.setLineCap(.round)
            context.move(to: CGPoint(x: CGFloat(a.x) + 0.5, y: CGFloat(a.y) + 0.5))
            context.addLine(to: CGPoint(x: CGFloat(b.x) + 0.5, y: CGFloat(b.y) + 0.5))
            context.strokePath()
        case .rectangle, .ellipse:
            let inner = box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            guard inner.width > 0, inner.height > 0 else {
                // Box thinner than the outline: it is all outline.
                context.setFillColor(style.outline.cgColor)
                if kind == .rectangle { context.fill(box) } else { context.fillEllipse(in: box) }
                break
            }
            let path = kind == .rectangle
                ? CGPath(rect: inner, transform: nil)
                : CGPath(ellipseIn: inner, transform: nil)
            if let fill = style.fill {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
            context.addPath(path)
            context.strokePath()
        }

        let pad = Int(lineWidth.rounded(.up)) + 1
        return PixelRect(enclosing: a, b).insetBy(dx: -pad, dy: -pad).intersection(bounds)
    }
}
