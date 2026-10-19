import AppKit
import PaintCore

/// The ribbon's icons: SF Symbols where one fits, and drawings of the app's own for the rest.
/// Brush icons are real strokes from the brush engine, so each previews what it paints.
enum RibbonIcons {
    /// An SF Symbol in one color, sized for a large (32 pt) or small (16 pt) button.
    static func symbol(_ name: String, size: CGFloat, color: NSColor? = nil, fallback: String = "questionmark.square") -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: size, height: size))
        var configuration = NSImage.SymbolConfiguration(pointSize: size * 0.78, weight: .regular)
        if let color { configuration = configuration.applying(.init(hierarchicalColor: color)) }
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        // Center the glyph in a square canvas so every icon has the same footprint.
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let glyph = symbol.size
            let scale = min(1, rect.width / glyph.width, rect.height / glyph.height)
            let drawn = NSSize(width: glyph.width * scale, height: glyph.height * scale)
            symbol.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            return true
        }
    }

    /// A paint bucket tipping out a drop (the Fill with Color tool).
    static func fillBucket(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 16
            NSGraphicsContext.current?.cgContext.saveGState()
            let transform = NSAffineTransform()
            transform.translateX(by: 7.5 * s, yBy: 8 * s)
            transform.rotate(byDegrees: -35)
            transform.concat()
            let body = NSBezierPath(roundedRect: NSRect(x: -4 * s, y: -3.5 * s, width: 8 * s, height: 9 * s), xRadius: 1.2 * s, yRadius: 1.2 * s)
            NSColor.controlBackgroundColor.setFill()
            body.fill()
            NSColor.labelColor.setStroke()
            body.lineWidth = s
            body.stroke()
            let handle = NSBezierPath()
            handle.appendArc(withCenter: NSPoint(x: 0, y: -3.5 * s), radius: 3.5 * s, startAngle: 180, endAngle: 360, clockwise: false)
            handle.lineWidth = 0.9 * s
            handle.stroke()
            NSGraphicsContext.current?.cgContext.restoreGState()
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: 13.5 * s, y: 8.5 * s))
            drop.curve(to: NSPoint(x: 13.5 * s, y: 14.5 * s), controlPoint1: NSPoint(x: 11 * s, y: 12 * s), controlPoint2: NSPoint(x: 11.5 * s, y: 14.5 * s))
            drop.curve(to: NSPoint(x: 13.5 * s, y: 8.5 * s), controlPoint1: NSPoint(x: 15.5 * s, y: 14.5 * s), controlPoint2: NSPoint(x: 16 * s, y: 12 * s))
            NSColor.systemBlue.setFill()
            drop.fill()
            return true
        }
    }

    /// A short wavy stroke painted with `kind`, as the Brushes gallery shows it.
    static func brush(_ kind: BrushKind, size: NSSize, color: RGBA = RGBA(63, 72, 204)) -> NSImage {
        let scale = 2
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        // Painted over black and over white, the two results give each pixel's coverage, so the
        // icon keeps the brush's translucency on any background.
        let onBlack = stroke(kind, width: width, height: height, color: color, background: .black)
        let onWhite = stroke(kind, width: width, height: height, color: color, background: .white)
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let b = onBlack[PixelPoint(x: x, y: y)], w = onWhite[PixelPoint(x: x, y: y)]
                let alpha = 255 - min(255, (Int(w.r) - Int(b.r) + Int(w.g) - Int(b.g) + Int(w.b) - Int(b.b)) / 3)
                pixels[y * width + x] = RGBA(min(b.r, UInt8(alpha)), min(b.g, UInt8(alpha)), min(b.b, UInt8(alpha)), UInt8(alpha)).packed
            }
        }
        guard let image = Bitmap.makeImage(pixels: pixels, width: width, height: height) else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }

    private static func stroke(_ kind: BrushKind, width: Int, height: Int, color: RGBA, background: RGBA) -> Bitmap {
        let bitmap = Bitmap(width: width, height: height, fill: background)
        let points = (0...24).map { k -> CGPoint in
            let t = Double(k) / 24
            return CGPoint(x: Double(width) * (0.12 + 0.76 * t), y: Double(height) * (0.5 - 0.28 * sin(t * 2 * .pi)))
        }
        let pixel = { (p: CGPoint) in PixelPoint(x: Int(p.x), y: Int(p.y)) }
        let thickness = Int(Double(height) * 0.22)
        if let medium = kind.medium {
            let layer = MediumLayer(medium: medium, color: color, limit: bitmap.bounds, seed: 5)
            var touched = PixelRect.zero
            for (a, b) in zip(points, points.dropFirst()) {
                touched = touched.union(layer.addSegment(from: a, width: Double(thickness), to: b, width: Double(thickness)))
            }
            bitmap.composite(layer, in: touched)
            return bitmap
        }
        var random = SeededRandom(seed: 3)
        for (a, b) in zip(points, points.dropFirst()) {
            switch kind {
            case .normal:
                bitmap.drawRoundBrushLine(from: pixel(a), to: pixel(b), diameter: thickness / 2, color: color)
            case .calligraphy45, .calligraphy135:
                bitmap.drawCalligraphyLine(from: pixel(a), to: pixel(b), width: thickness, kind: kind, color: color)
            case .airbrush:
                bitmap.spray(at: pixel(b), size: thickness, color: color, using: &random)
            case .oil, .crayon, .marker, .naturalPencil, .watercolor:
                break
            }
        }
        return bitmap
    }

    /// A shape's outline, for the shape gallery.
    static func shape(_ kind: ShapeKind, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let box = rect.insetBy(dx: size / 8, dy: size / 8)
            let path: CGPath
            switch kind {
            case .line:
                let line = CGMutablePath()
                line.move(to: CGPoint(x: box.minX, y: box.maxY))
                line.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                path = line
            case .curve:
                let curve = CGMutablePath()
                curve.move(to: CGPoint(x: box.minX, y: box.maxY))
                curve.addCurve(to: CGPoint(x: box.maxX, y: box.minY), control1: CGPoint(x: box.minX, y: box.minY), control2: CGPoint(x: box.maxX, y: box.maxY))
                path = curve
            case .polygon:
                let polygon = CGMutablePath()
                polygon.addLines(between: [
                    CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX + box.width * 0.25, y: box.minY),
                    CGPoint(x: box.maxX, y: box.minY + box.height * 0.33), CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.maxX, y: box.maxY),
                ])
                polygon.closeSubpath()
                path = polygon
            default:
                path = ShapeGeometry.path(for: kind, in: box) ?? CGPath(rect: box, transform: nil)
            }
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(size / 13)
            context.strokePath()
            return true
        }
    }

    /// A horizontal line `thickness` pixels thick, for the Size gallery.
    static func line(thickness: Int, width: CGFloat = 70) -> NSImage {
        let height = max(CGFloat(thickness) + 6, 14)
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.labelColor.setFill()
            NSRect(x: 2, y: ((rect.height - CGFloat(thickness)) / 2).rounded(), width: rect.width - 4, height: CGFloat(thickness)).fill()
            return true
        }
    }

    /// Four lines of growing thickness: the Size button.
    static func sizes(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            NSColor.labelColor.setFill()
            var y = rect.height * 0.16
            for thickness in [1.0, 2.0, 3.5, 5.0] {
                NSRect(x: rect.width * 0.12, y: y, width: rect.width * 0.76, height: thickness * rect.height / 32).fill()
                y += (thickness + 4.5) * rect.height / 32
            }
            return true
        }
    }

    /// A rounded square of `color` with a border: the Color 1 and Color 2 buttons and the
    /// custom color slots.
    static func swatch(_ color: RGBA?, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            (color?.nsColor ?? .controlBackgroundColor).setFill()
            square.fill()
            NSColor.separatorColor.setStroke()
            square.lineWidth = 1
            square.stroke()
            return true
        }
    }

    /// A hue wheel: the Edit Colors button.
    static func colorWheel(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width * 0.42
            for step in 0..<36 {
                let start = CGFloat(step) * 10, end = start + 10.5
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
                wedge.close()
                NSColor(hue: CGFloat(step) / 36, saturation: 0.85, brightness: 1, alpha: 1).setFill()
                wedge.fill()
            }
            let core = NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.38, y: center.y - radius * 0.38, width: radius * 0.76, height: radius * 0.76))
            NSColor.white.setFill()
            core.fill()
            return true
        }
    }

    /// The Outline drop-down: a shape outline with a pen.
    static func outline(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 16
            let shape = NSBezierPath(ovalIn: NSRect(x: 1.5 * s, y: 4.5 * s, width: 10 * s, height: 9 * s))
            shape.lineWidth = 1.4 * s
            NSColor.labelColor.setStroke()
            shape.stroke()
            symbol("pencil", size: 9 * s).draw(in: NSRect(x: 7 * s, y: 0, width: 9 * s, height: 9 * s))
            return true
        }
    }

    /// The Fill drop-down: a filled shape.
    static func fill(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 16
            let shape = NSBezierPath(ovalIn: NSRect(x: 1.5 * s, y: 4.5 * s, width: 10 * s, height: 9 * s))
            NSColor.systemOrange.setFill()
            shape.fill()
            NSColor.labelColor.setStroke()
            shape.lineWidth = s
            shape.stroke()
            fillBucket(size: 9 * s).draw(in: NSRect(x: 7 * s, y: 0, width: 9 * s, height: 9 * s))
            return true
        }
    }
}

/// A repeatable random sequence, so icons look the same every time.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
