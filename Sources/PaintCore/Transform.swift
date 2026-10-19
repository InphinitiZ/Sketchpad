import Foundation

/// A detached block of pixels, row-major. Transforms work on these so the same code serves
/// the whole picture and a floating selection.
public struct PixelGrid: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt32]

    public init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, filledWith value: UInt32) {
        self.init(width: width, height: height, pixels: [UInt32](repeating: value, count: width * height))
    }

    public subscript(x: Int, y: Int) -> UInt32 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

public enum Rotation: Sendable {
    case clockwise
    case counterclockwise
    case halfTurn
}

/// The Image menu operations. Paint applies them to the selection if there is one,
/// otherwise to the whole picture.
public enum CanvasTransform: Equatable, Sendable {
    case flipHorizontal
    case flipVertical
    case rotate(Rotation)
    case resize(width: Int, height: Int)
    /// Positive angles lean the top to the right (the bottom row stays put).
    case skewHorizontal(degrees: Int)
    /// Positive angles push the left edge down (the right column stays put).
    case skewVertical(degrees: Int)
    /// Paint's Invert Color: every channel becomes 255 minus itself.
    case invertColors
    /// Dragging a selection handle: rows and columns are repeated or dropped without blending
    /// (`CImgBrush::SetSize` uses StretchBlt in COLORONCOLOR mode).
    case stretch(width: Int, height: Int)
}

extension CanvasTransform {
    /// The size of a `width`×`height` picture after this transform, without doing it.
    public func resultSize(width: Int, height: Int) -> (width: Int, height: Int) {
        switch self {
        case .flipHorizontal, .flipVertical, .invertColors, .rotate(.halfTurn): (width, height)
        case .rotate: (height, width)
        case let .resize(w, h), let .stretch(w, h): (w, h)
        case let .skewHorizontal(degrees): (width + Skew.offset(height, degrees: degrees), height)
        case let .skewVertical(degrees): (width, height + Skew.offset(width, degrees: degrees))
        }
    }
}

/// Paint's integer shear, from `CImgWnd::CmdSkewBrush`.
public enum Skew {
    public static let maxDegrees = 89

    /// How far row or column `k` moves for an angle: `(k·10⁶ / T + 5) / 10` with integer
    /// division, where `T = round(100000·cot θ)` is the entry in Paint's 1–89° table.
    public static func offset(_ k: Int, degrees: Int) -> Int {
        let angle = abs(degrees)
        guard angle > 0 else { return 0 }
        precondition(angle <= maxDegrees, "Paint limits skew to ±89°")
        let cotangent = Int((100_000 / tan(Double(angle) * .pi / 180)).rounded())
        return (k * 1_000_000 / cotangent + 5) / 10
    }
}

extension PixelGrid {
    /// The grid after `transform`. Areas a skew uncovers are filled with `background`.
    public func applying(_ transform: CanvasTransform, background: UInt32) -> PixelGrid {
        switch transform {
        case .flipHorizontal:
            return remapped(width: width, height: height) { x, y in (width - 1 - x, y) }
        case .flipVertical:
            return remapped(width: width, height: height) { x, y in (x, height - 1 - y) }
        case .rotate(.clockwise):
            return remapped(width: height, height: width) { x, y in (y, height - 1 - x) }
        case .rotate(.counterclockwise):
            return remapped(width: height, height: width) { x, y in (width - 1 - y, x) }
        case .rotate(.halfTurn):
            return remapped(width: width, height: height) { x, y in (width - 1 - x, height - 1 - y) }
        case let .resize(newWidth, newHeight):
            return resampled(width: newWidth, height: newHeight)
        case let .stretch(newWidth, newHeight):
            // Each target pixel takes the source pixel under its center.
            return remapped(width: newWidth, height: newHeight) { x, y in
                ((2 * x + 1) * width / (2 * newWidth), (2 * y + 1) * height / (2 * newHeight))
            }
        case let .skewHorizontal(degrees):
            return skewed(degrees: degrees, horizontal: true, background: background)
        case let .skewVertical(degrees):
            return skewed(degrees: degrees, horizontal: false, background: background)
        case .invertColors:
            var result = self
            for i in pixels.indices { result.pixels[i] = pixels[i] ^ 0x00FF_FFFF }
            return result
        }
    }

    /// Builds a grid of the given size where each pixel comes from `source(x, y)` in `self`.
    private func remapped(width newWidth: Int, height newHeight: Int, source: (Int, Int) -> (Int, Int)) -> PixelGrid {
        var result = PixelGrid(width: newWidth, height: newHeight, filledWith: 0)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let (sx, sy) = source(x, y)
                result[x, y] = self[sx, sy]
            }
        }
        return result
    }

    private func skewed(degrees: Int, horizontal: Bool, background: UInt32) -> PixelGrid {
        guard degrees != 0 else { return self }
        // The edge that does not move: bottom row (horizontal) or right column (vertical).
        let lines = horizontal ? height : width
        let extra = Skew.offset(lines, degrees: degrees)
        func shift(_ line: Int) -> Int {
            let lean = Skew.offset(lines - 1 - line, degrees: degrees)
            return degrees > 0 ? lean : extra - lean
        }

        var result = horizontal
            ? PixelGrid(width: width + extra, height: height, filledWith: background)
            : PixelGrid(width: width, height: height + extra, filledWith: background)
        for y in 0..<height {
            for x in 0..<width {
                if horizontal {
                    result[x + shift(y), y] = self[x, y]
                } else {
                    result[x, y + shift(x)] = self[x, y]
                }
            }
        }
        return result
    }

    /// Area-weighted resampling: each output pixel averages the source pixels its footprint
    /// covers. Shrinking blends (like GDI's HALFTONE mode, which Paint sets for color images);
    /// enlarging by a whole factor copies pixels exactly.
    private func resampled(width newWidth: Int, height newHeight: Int) -> PixelGrid {
        precondition(newWidth > 0 && newHeight > 0)
        if newWidth == width && newHeight == height { return self }
        let columns = Self.footprints(from: width, to: newWidth)
        let rows = Self.footprints(from: height, to: newHeight)

        // Horizontal pass into floating-point channels, then vertical pass back to bytes.
        var horizontal = [SIMD4<Double>](repeating: .zero, count: newWidth * height)
        for y in 0..<height {
            for (x, taps) in columns.enumerated() {
                var sum = SIMD4<Double>.zero
                for (sx, weight) in taps { sum += Self.channels(self[sx, y]) * weight }
                horizontal[y * newWidth + x] = sum
            }
        }
        var result = PixelGrid(width: newWidth, height: newHeight, filledWith: 0)
        for (y, taps) in rows.enumerated() {
            for x in 0..<newWidth {
                var sum = SIMD4<Double>.zero
                for (sy, weight) in taps { sum += horizontal[sy * newWidth + x] * weight }
                result[x, y] = Self.packed(sum)
            }
        }
        return result
    }

    /// For each output index, the source indices it overlaps and their share of its footprint.
    private static func footprints(from sourceCount: Int, to count: Int) -> [[(Int, Double)]] {
        let scale = Double(sourceCount) / Double(count)
        return (0..<count).map { i in
            let start = Double(i) * scale, end = start + scale
            var taps: [(Int, Double)] = []
            var s = Int(start)
            while Double(s) < end && s < sourceCount {
                let overlap = min(end, Double(s + 1)) - max(start, Double(s))
                if overlap > 1e-9 { taps.append((s, overlap / scale)) }
                s += 1
            }
            return taps
        }
    }

    private static func channels(_ value: UInt32) -> SIMD4<Double> {
        SIMD4(Double(value & 0xFF), Double(value >> 8 & 0xFF), Double(value >> 16 & 0xFF), Double(value >> 24))
    }

    private static func packed(_ c: SIMD4<Double>) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32(min(max(v.rounded(), 0), 255)) }
        return byte(c.x) | byte(c.y) << 8 | byte(c.z) << 16 | byte(c.w) << 24
    }
}

extension Bitmap {
    public var grid: PixelGrid { PixelGrid(width: width, height: height, pixels: copyPixels()) }

    public convenience init(grid: PixelGrid) {
        self.init(width: grid.width, height: grid.height, pixels: grid.pixels)
    }
}

extension SelectionMask {
    /// The mask after `transform`, keeping its top-left corner. Rectangular selections stay
    /// rectangular (a skewed rectangle's corners are background pixels, still selected, as in
    /// Paint); free-form masks and their outlines are transformed with the pixels.
    public func applying(_ transform: CanvasTransform) -> SelectionMask {
        guard transform != .invertColors else { return self }
        let size = PixelGrid(width: rect.width, height: rect.height, filledWith: 0).applying(transform, background: 0)
        let newRect = PixelRect(x: rect.x, y: rect.y, width: size.width, height: size.height)
        guard let outline else { return SelectionMask(rect: newRect) }

        let on: UInt32 = 0xFFFF_FFFF
        var bitsGrid = PixelGrid(width: rect.width, height: rect.height, filledWith: 0)
        for y in 0..<rect.height {
            for x in 0..<rect.width where covers(localX: x, localY: y) { bitsGrid[x, y] = on }
        }
        let transformed = bitsGrid.applying(transform, background: 0)
        // Resampling blends the edge; keep pixels that are at least half selected.
        let bits = transformed.pixels.map { $0 & 0xFF >= 128 }
        let points = outline.map { Self.map($0, from: rect.width, rect.height, by: transform) }
        return SelectionMask(rect: newRect, bits: bits, outline: points)
    }

    private static func map(_ p: PixelPoint, from width: Int, _ height: Int, by transform: CanvasTransform) -> PixelPoint {
        switch transform {
        case .flipHorizontal:
            return PixelPoint(x: width - 1 - p.x, y: p.y)
        case .flipVertical:
            return PixelPoint(x: p.x, y: height - 1 - p.y)
        case .rotate(.clockwise):
            return PixelPoint(x: height - 1 - p.y, y: p.x)
        case .rotate(.counterclockwise):
            return PixelPoint(x: p.y, y: width - 1 - p.x)
        case .rotate(.halfTurn):
            return PixelPoint(x: width - 1 - p.x, y: height - 1 - p.y)
        case let .resize(newWidth, newHeight), let .stretch(newWidth, newHeight):
            return PixelPoint(x: p.x * newWidth / width, y: p.y * newHeight / height)
        case let .skewHorizontal(degrees):
            let extra = Skew.offset(height, degrees: degrees)
            let lean = Skew.offset(height - 1 - p.y, degrees: degrees)
            return PixelPoint(x: p.x + (degrees > 0 ? lean : extra - lean), y: p.y)
        case let .skewVertical(degrees):
            let extra = Skew.offset(width, degrees: degrees)
            let lean = Skew.offset(width - 1 - p.x, degrees: degrees)
            return PixelPoint(x: p.x, y: p.y + (degrees > 0 ? lean : extra - lean))
        case .invertColors:
            return p
        }
    }
}

extension SelectionSession {
    /// Transforms the selection in place (lifting it first), keeping its top-left corner.
    /// Returns the canvas area that changed.
    @discardableResult
    public func apply(_ transform: CanvasTransform, background: RGBA) -> PixelRect {
        lift(background: background, transparent: transparentColor)
        return replaceFloating { grid, mask in
            (grid.applying(transform, background: background.packed), mask.applying(transform))
        }
    }
}

extension PixelGrid {
    /// Image Properties' width and height change the canvas, not the picture: it keeps its
    /// top-left corner and is cut off or extended with `background`.
    public func withCanvasSize(width newWidth: Int, height newHeight: Int, background: UInt32) -> PixelGrid {
        precondition(newWidth > 0 && newHeight > 0)
        var result = PixelGrid(width: newWidth, height: newHeight, filledWith: background)
        for y in 0..<min(height, newHeight) {
            for x in 0..<min(width, newWidth) {
                result[x, y] = self[x, y]
            }
        }
        return result
    }

    /// Image Properties' "Black and white": each pixel becomes black or white by its
    /// luminance (Rec. 601 weights, threshold at the midpoint).
    public func blackAndWhite() -> PixelGrid {
        var result = self
        for i in pixels.indices {
            let c = RGBA(packed: pixels[i])
            let luminance = 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
            result.pixels[i] = (luminance >= 128 ? RGBA.white : RGBA.black).packed
        }
        return result
    }
}
