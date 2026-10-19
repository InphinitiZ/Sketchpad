import CoreGraphics
import Foundation

/// Paint's artistic media: the oil brush, crayon, marker, natural pencil and watercolor brush,
/// which also serve as shape outlines and fills.
///
/// Paint draws them as PGS skeletal strokes (`PGSSkeletalStrokeHelper`): a texture is mapped
/// along the stroke, running lengthwise with the path and spanning its width, and used purely
/// as an opacity mask over the solid color (`Scanline` takes the texel's green channel as alpha
/// and never tints the color). The textures here are this app's own, generated procedurally;
/// the mapping and blending rules follow Paint.
public enum Medium: CaseIterable, Sendable {
    case oil, crayon, marker, naturalPencil, watercolor

    /// How much pen pressure widens or narrows the stroke (the `k1` of the media's
    /// `PGS_SKELETALSTROKEBRUSH_PARAM`, with `c1` = ½). Marker and natural pencil ignore it.
    public var pressureGain: Double {
        switch self {
        case .oil, .watercolor: 20
        case .crayon: 10
        case .marker, .naturalPencil: 0
        }
    }

    /// The stroke width in pixels for a brush size and pen pressure (0…1, `nil` for a mouse):
    /// size + (pressure − ½)·k, so oil and watercolor vary by ±10 px and crayon by ±5 px.
    public func strokeWidth(size: Int, pressure: Double?) -> Double {
        guard let pressure else { return Double(size) }
        return max(1, Double(size) + (pressure - 0.5) * pressureGain)
    }

    /// Shape outlines use the texture from 4 px up; thinner ones, and the marker, are drawn in
    /// solid color (`CDrawShapeOperation::RefreshBrushes`).
    public func texturesOutline(width: Int) -> Bool { self != .marker && width >= 4 }

    /// The marker's shape fill is solid; the others are textured.
    public var texturesFill: Bool { self != .marker }
}

/// One textured stroke or shape part, built up piece by piece and then painted over the canvas.
///
/// Paint maps the texture onto one continuous strip along the stroke and composites the strip
/// into a layer with source-over, so the stroke builds up only where it crosses itself. Here
/// the stroke arrives as straight pieces whose round ends overlap at every joint; a pixel
/// counts as crossed when a piece reaches it from a part of the stroke well away (along the
/// path) from the part that painted it first.
public final class MediumLayer {
    public let medium: Medium
    public let color: RGBA
    /// The area the layer may grow into (the canvas).
    public let limit: PixelRect
    /// The area allocated so far.
    public private(set) var area = PixelRect.zero
    private let seed: UInt32

    /// The opacity the latest pass over each pixel lays down.
    private var alpha: [Float] = []
    /// How far along the stroke that pass was, or −1 if no pass has reached the pixel.
    private var arc: [Float] = []
    /// What earlier passes let through (1: nothing painted underneath).
    private var through: [Float] = []

    /// The stroke length so far, which places the texture along the stroke.
    private var travelled = 0.0
    /// A closed outline's length, after which it meets its own start.
    private var loopLength: Double?

    public init(medium: Medium, color: RGBA, limit: PixelRect, seed: UInt32 = 0) {
        self.medium = medium
        self.color = color
        self.limit = limit
        self.seed = seed
    }

    /// Adds a stroke piece from `a` to `b` whose width goes from `wa` to `wb` (it varies with
    /// pen pressure). Returns the area it touched.
    @discardableResult
    public func addSegment(from a: CGPoint, width wa: Double, to b: CGPoint, width wb: Double) -> PixelRect {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let length = length2.squareRoot()
        defer { travelled += length }

        let reach = max(wa, wb) / 2 + 1
        let touched = PixelRect(
            x: Int((min(a.x, b.x) - reach).rounded(.down)),
            y: Int((min(a.y, b.y) - reach).rounded(.down)),
            width: Int((abs(dx) + 2 * reach).rounded(.up)) + 1,
            height: Int((abs(dy) + 2 * reach).rounded(.up)) + 1
        ).intersection(limit)
        guard !touched.isEmpty else { return .zero }
        grow(to: touched)

        // Unit vector across the stroke, from its left edge to its right.
        let (nx, ny) = length > 0 ? (-dy / length, dx / length) : (0.0, 1.0)
        for y in touched.y..<touched.maxY {
            for x in touched.x..<touched.maxX {
                let px = Double(x) + 0.5 - a.x, py = Double(y) + 0.5 - a.y
                let t = length2 > 0 ? min(max((px * dx + py * dy) / length2, 0), 1) : 0
                let cx = px - t * dx, cy = py - t * dy
                let width = wa + (wb - wa) * t
                let radius = width / 2
                let edge = min(max(radius - (cx * cx + cy * cy).squareRoot() + 0.5, 0), 1)
                guard edge > 0 else { continue }
                let across = min(max((cx * nx + cy * ny + radius) / width, 0), 1)
                let along = travelled + t * length
                let opacity = edge * strokeTexture(along: along, across: across, width: width)
                // On the inside of a tight bend a wide stroke folds over itself within about
                // two widths of path; only farther apart is it a real crossing.
                lay(Float(opacity), at: x, y, along: along, joinDistance: 2 * width + 2)
            }
        }
        return touched
    }

    /// Adds a stroke of fixed `width` along `points` (a textured shape outline). A closed run
    /// ends at its first point and joins up without a crossing there.
    @discardableResult
    public func addPolyline(_ points: [CGPoint], width: Double) -> PixelRect {
        guard let first = points.first else { return .zero }
        travelled = 0
        let closed = points.count > 2 && points.last == first
        loopLength = closed ? zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } : nil
        defer { loopLength = nil }
        var touched = PixelRect.zero
        for (a, b) in zip(points, points.dropFirst()) {
            touched = touched.union(addSegment(from: a, width: width, to: b, width: width))
        }
        return points.count == 1 ? addSegment(from: first, width: width, to: first, width: width) : touched
    }

    /// Adds the inside of `path` (a textured shape fill). Paint tiles the fill texture unrotated
    /// and unscaled from `origin`, the shape's top-left corner. Returns the area it touched.
    @discardableResult
    public func addFill(_ path: CGPath, origin: CGPoint) -> PixelRect {
        let box = path.boundingBoxOfPath
        let touched = PixelRect(
            x: Int(box.minX.rounded(.down)) - 1,
            y: Int(box.minY.rounded(.down)) - 1,
            width: Int(box.width.rounded(.up)) + 3,
            height: Int(box.height.rounded(.up)) + 3
        ).intersection(limit)
        guard !touched.isEmpty, let mask = Self.mask(of: path, in: touched) else { return .zero }
        grow(to: touched)
        for row in 0..<touched.height {
            for column in 0..<touched.width where mask[row * touched.width + column] > 0 {
                let x = touched.x + column, y = touched.y + row
                let coverage = Double(mask[row * touched.width + column]) / 255
                let opacity = coverage * fillTexture(x: Double(x) - origin.x, y: Double(y) - origin.y)
                let i = index(x, y)
                alpha[i] = max(alpha[i], Float(opacity))
                arc[i] = 0
            }
        }
        return touched
    }

    /// The layer's opacity over the pixel at (`x`, `y`), counting every pass.
    public func opacity(atX x: Int, y: Int) -> Double {
        guard area.contains(PixelPoint(x: x, y: y)) else { return 0 }
        let i = index(x, y)
        return 1 - Double(through[i]) * (1 - Double(alpha[i]))
    }

    // MARK: - Passes

    private func lay(_ opacity: Float, at x: Int, _ y: Int, along: Double, joinDistance: Double) {
        let i = index(x, y)
        guard arc[i] >= 0 else {
            alpha[i] = opacity
            arc[i] = Float(along)
            return
        }
        var gap = abs(along - Double(arc[i]))
        if let loopLength { gap = min(gap, loopLength - gap) }
        if gap <= joinDistance {
            // The neighboring piece of the same pass: the stronger texel wins.
            if opacity > alpha[i] {
                alpha[i] = opacity
                arc[i] = Float(along)
            }
        } else {
            // The stroke comes back over itself: the earlier pass is now underneath.
            through[i] *= 1 - alpha[i]
            alpha[i] = opacity
            arc[i] = Float(along)
        }
    }

    private func index(_ x: Int, _ y: Int) -> Int {
        (y - area.y) * area.width + (x - area.x)
    }

    /// Makes room for `rect`, keeping what is there. Strokes start small and grow in 64-pixel
    /// steps, so a brush stroke does not cost a canvas-sized buffer.
    private func grow(to rect: PixelRect) {
        guard !area.contains(rect) else { return }
        let wanted = area.isEmpty ? rect : area.union(rect)
        let newArea = wanted.insetBy(dx: -64, dy: -64).intersection(limit)
        let count = newArea.width * newArea.height
        var newAlpha = [Float](repeating: 0, count: count)
        var newArc = [Float](repeating: -1, count: count)
        var newThrough = [Float](repeating: 1, count: count)
        if !area.isEmpty {
            for y in area.y..<area.maxY {
                let from = (y - area.y) * area.width
                let to = (y - newArea.y) * newArea.width + (area.x - newArea.x)
                for k in 0..<area.width {
                    newAlpha[to + k] = alpha[from + k]
                    newArc[to + k] = arc[from + k]
                    newThrough[to + k] = through[from + k]
                }
            }
        }
        area = newArea
        alpha = newAlpha
        arc = newArc
        through = newThrough
    }

    // MARK: - Textures

    /// The stroke texture's opacity `along` pixels down the stroke and `across` (0…1) from its
    /// left edge to its right, for a stroke `width` pixels wide.
    private func strokeTexture(along u: Double, across v: Double, width w: Double) -> Double {
        let side = v * w
        switch medium {
        case .marker:
            return 0.5
        case .crayon:
            // Wax catches on the paper's tooth and skips the hollows; thin crayons have a finer grain.
            let scale = max(0.8, min(w, 24) / 12)
            let grain = 0.6 * Texture.noise(u / scale, side / scale, seed: seed &+ 11) + 0.4 * Texture.hash(Int(u), Int(side), seed: seed &+ 12)
            return 0.95 * Texture.smoothstep(0.32, 0.62, grain)
        case .naturalPencil:
            let grain = 0.5 * Texture.noise(u / 1.5, side / 1.5, seed: seed &+ 21) + 0.5 * Texture.hash(Int(u), Int(side), seed: seed &+ 22)
            let line = 0.75 + 0.25 * Texture.hash(Int(side), 0, seed: seed &+ 23)
            return line * (0.18 + 0.55 * Texture.smoothstep(0.25, 0.85, grain))
        case .watercolor:
            // A thin wash, darker where the water dried at the edges, unevenly mottled.
            let rim = 1 - Texture.smoothstep(0, 0.45, 2 * min(v, 1 - v))
            let mottle = Texture.noise(u / 9, side / 9, seed: seed &+ 31) - 0.5
            return 0.22 + 0.25 * rim + 0.12 * mottle
        case .oil:
            // Thick paint in bristle streaks that run the length of the stroke.
            let bristles = max(3, Int(w / 2.5))
            let bristle = min(bristles - 1, Int(v * Double(bristles)))
            let load = Texture.hash(bristle, 0, seed: seed &+ 41)
            let drag = Texture.noise(u / 25, Double(bristle) * 7.3, seed: seed &+ 42)
            return (0.55 + 0.45 * load) * (0.85 + 0.15 * drag)
        }
    }

    /// The fill texture's opacity at (`x`, `y`) from the shape's corner.
    private func fillTexture(x: Double, y: Double) -> Double {
        switch medium {
        case .marker:
            return 1
        case .crayon:
            let grain = 0.6 * Texture.noise(x / 2.2, y / 2.2, seed: 13) + 0.4 * Texture.hash(Int(x), Int(y), seed: 14)
            return 0.95 * Texture.smoothstep(0.32, 0.62, grain)
        case .naturalPencil:
            // Diagonal hatching.
            let stripe = (x + y).truncatingRemainder(dividingBy: 4)
            let grain = Texture.hash(Int(x), Int(y), seed: 24)
            return stripe < 1.5 ? 0.35 + 0.4 * grain : 0.05 + 0.1 * grain
        case .watercolor:
            return 0.3 + 0.15 * (Texture.noise(x / 12, y / 12, seed: 33) - 0.5) + 0.1 * (Texture.noise(x / 40, y / 40, seed: 34) - 0.5)
        case .oil:
            // Horizontal brush strokes.
            let band = Int(y / 3)
            let drift = Texture.hash(band, 0, seed: 43) * 100
            return 0.6 + 0.4 * Texture.noise(x / 30 + drift, Double(band), seed: 44)
        }
    }

    /// The antialiased inside of `path` over `rect`, one byte per pixel, rows from the top.
    private static func mask(of path: CGPath, in rect: PixelRect) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: rect.width * rect.height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: rect.width, height: rect.height, bitsPerComponent: 8,
                bytesPerRow: rect.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // Top-left origin, like the canvas.
            context.translateBy(x: 0, y: CGFloat(rect.height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: CGFloat(-rect.x), y: CGFloat(-rect.y))
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath()
            return true
        }
        return drawn ? bytes : nil
    }
}

/// Deterministic noise for the procedural textures.
enum Texture {
    /// A pseudo-random value in [0, 1) for a lattice point.
    static func hash(_ x: Int, _ y: Int, seed: UInt32) -> Double {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343
        h ^= UInt32(truncatingIfNeeded: y) &* 0xD816_3841
        h ^= seed &* 0xCB1A_B31F
        h ^= h >> 13
        h &*= 0x5BD1_E995
        h ^= h >> 15
        return Double(h) / 4_294_967_296
    }

    /// Smoothly interpolated lattice noise in [0, 1).
    static func noise(_ x: Double, _ y: Double, seed: UInt32) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = smoothstep(0, 1, x - Double(x0)), fy = smoothstep(0, 1, y - Double(y0))
        let top = hash(x0, y0, seed: seed) * (1 - fx) + hash(x0 + 1, y0, seed: seed) * fx
        let bottom = hash(x0, y0 + 1, seed: seed) * (1 - fx) + hash(x0 + 1, y0 + 1, seed: seed) * fx
        return top * (1 - fy) + bottom * fy
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

extension Bitmap {
    /// Paints `layer`'s color inside `rect` at the layer's opacity, over `base` (a
    /// `copyPixels()` buffer of the canvas before the stroke) or over the current pixels when
    /// `base` is `nil`.
    public func composite(_ layer: MediumLayer, in rect: PixelRect, over base: [UInt32]? = nil) {
        let rect = rect.intersection(bounds)
        guard !rect.isEmpty else { return }
        let color = layer.color
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX {
                let i = y * width + x
                let under = base?[i] ?? storage[i]
                let alpha = layer.opacity(atX: x, y: y)
                guard alpha > 0 else {
                    storage[i] = under
                    continue
                }
                let b = RGBA(packed: under)
                func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
                    UInt8((Double(top) * alpha + Double(bottom) * (1 - alpha)).rounded())
                }
                storage[i] = RGBA(mix(color.r, b.r), mix(color.g, b.g), mix(color.b, b.b), 255).packed
            }
        }
    }
}

extension CGPath {
    /// The path as connected point runs, with curves cut into short straight pieces (as Paint
    /// flattens a shape's path before stroking it with a texture). A closed subpath ends where
    /// it started.
    public func polylines() -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finish() {
            if !current.isEmpty { runs.append(current) }
            current = []
        }
        func steps(_ points: [CGPoint]) -> Int {
            let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            return max(4, Int((length / 3).rounded(.up)))
        }
        applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                finish()
                current = [e.points[0]]
            case .addLineToPoint:
                current.append(e.points[0])
            case .addQuadCurveToPoint:
                guard let p0 = current.last else { return }
                let c = e.points[0], p1 = e.points[1]
                let n = steps([p0, c, p1])
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    current.append(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                                           y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y))
                }
            case .addCurveToPoint:
                guard let p0 = current.last else { return }
                let c1 = e.points[0], c2 = e.points[1], p1 = e.points[2]
                let n = steps([p0, c1, c2, p1])
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                                           y: a * p0.y + b * c1.y + c * c2.y + d * p1.y))
                }
            case .closeSubpath:
                if let first = current.first, current.last != first { current.append(first) }
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return runs
    }
}
