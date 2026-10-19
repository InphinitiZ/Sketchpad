import CoreGraphics

/// Which pixels a selection covers. Rectangular selections cover all of `rect`; free-form
/// ones keep a per-pixel mask plus the traced outline for drawing the marquee.
public struct SelectionMask: Equatable, Sendable {
    /// Where the selection sits on the canvas.
    public private(set) var rect: PixelRect
    /// Row-major over `rect`; `nil` means every pixel.
    private let bits: [Bool]?
    /// The traced free-form outline, relative to `rect`'s origin.
    public let outline: [PixelPoint]?

    public init(rect: PixelRect) {
        self.rect = rect
        bits = nil
        outline = nil
    }

    /// Rasterizes a free-form outline: pixels whose centers fall inside it (even-odd rule)
    /// plus the traced line itself, clipped to `bounds`. `nil` when nothing is left.
    public init?(polygon points: [PixelPoint], within bounds: PixelRect) {
        guard points.count >= 3 else { return nil }
        let rect = points.dropFirst()
            .reduce(PixelRect(enclosing: points[0], points[0])) { $0.union(PixelRect(enclosing: $1, $1)) }
            .intersection(bounds)
        guard !rect.isEmpty else { return nil }

        var bits = [Bool](repeating: false, count: rect.width * rect.height)
        func set(_ x: Int, _ y: Int) {
            guard x >= rect.x, x < rect.maxX, y >= rect.y, y < rect.maxY else { return }
            bits[(y - rect.y) * rect.width + (x - rect.x)] = true
        }

        for y in rect.y..<rect.maxY {
            let centerY = Double(y) + 0.5
            var crossings: [Double] = []
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                let ay = Double(a.y) + 0.5, by = Double(b.y) + 0.5
                if (ay <= centerY) != (by <= centerY) {
                    let t = (centerY - ay) / (by - ay)
                    crossings.append(Double(a.x) + 0.5 + t * Double(b.x - a.x))
                }
            }
            crossings.sort()
            for pair in stride(from: 0, to: crossings.count - 1, by: 2) {
                let first = Int((crossings[pair] - 0.5).rounded(.up))
                let last = Int((crossings[pair + 1] - 0.5).rounded(.down))
                if first <= last { for x in first...last { set(x, y) } }
            }
        }
        for i in points.indices {
            Raster.linePoints(from: points[i], to: points[(i + 1) % points.count]) { set($0.x, $0.y) }
        }

        self.rect = rect
        self.bits = bits
        outline = points.map { PixelPoint(x: $0.x - rect.x, y: $0.y - rect.y) }
    }

    public var isRectangular: Bool { bits == nil }

    /// Whether the selection covers the canvas pixel `p`.
    public func contains(_ p: PixelPoint) -> Bool {
        guard p.x >= rect.x, p.x < rect.maxX, p.y >= rect.y, p.y < rect.maxY else { return false }
        return covers(localX: p.x - rect.x, localY: p.y - rect.y)
    }

    func covers(localX x: Int, localY y: Int) -> Bool {
        bits?[y * rect.width + x] ?? true
    }

    public func offsetBy(dx: Int, dy: Int) -> SelectionMask {
        var moved = self
        moved.rect.x += dx
        moved.rect.y += dy
        return moved
    }
}

extension Bitmap {
    /// The pixels of `mask.rect`, row-major, with pixels outside the mask set to `outside`.
    /// `mask.rect` must lie within the canvas.
    public func pixels(in mask: SelectionMask, outside: RGBA) -> [UInt32] {
        let rect = mask.rect
        precondition(rect.intersection(bounds) == rect, "selection must lie within the canvas")
        var pixels = [UInt32](repeating: outside.packed, count: rect.width * rect.height)
        for y in 0..<rect.height {
            let row = (rect.y + y) * width + rect.x
            for x in 0..<rect.width where mask.covers(localX: x, localY: y) {
                pixels[y * rect.width + x] = storage[row + x]
            }
        }
        return pixels
    }

    @discardableResult
    public func fill(_ mask: SelectionMask, with color: RGBA) -> PixelRect {
        stamp([UInt32](repeating: color.packed, count: mask.rect.width * mask.rect.height), mask: mask, skipping: nil)
    }

    /// Draws `pixels` (laid out over `mask.rect`) where the mask is set, leaving out pixels
    /// equal to `transparent`. Anything off the canvas is clipped.
    @discardableResult
    public func stamp(_ pixels: [UInt32], mask: SelectionMask, skipping transparent: RGBA?) -> PixelRect {
        let rect = mask.rect
        let visible = rect.intersection(bounds)
        guard !visible.isEmpty else { return .zero }
        let skip = transparent?.packed
        for y in visible.y..<visible.maxY {
            let localY = y - rect.y
            for x in visible.x..<visible.maxX {
                let localX = x - rect.x
                guard mask.covers(localX: localX, localY: localY) else { continue }
                let value = pixels[localY * rect.width + localX]
                if value != skip { storage[y * width + x] = value }
            }
        }
        return visible
    }

    /// An image of a pixel buffer such as one from `pixels(in:outside:)`.
    public static func makeImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        Bitmap(width: width, height: height, pixels: pixels).makeImage()
    }
}

/// One selection, from the moment it is made until it is deselected.
///
/// Like Paint's `CImgBrush`, a moved selection is drawn into the bitmap at each step: `base`
/// keeps the canvas without the floating pixels so the previous position can be restored.
/// The bitmap therefore always shows what will be saved.
public final class SelectionSession {
    public private(set) var mask: SelectionMask
    /// The canvas as it was when the session began, for the undo snapshot.
    public let before: [UInt32]
    /// Everything this session has changed on the canvas.
    public private(set) var dirty = PixelRect.zero
    /// Pixels equal to this color are left out when the selection is drawn (transparent selection).
    public private(set) var transparentColor: RGBA?

    private let bitmap: Bitmap
    private var floating: [UInt32]?
    private var base: [UInt32]?

    /// Selects part of the canvas. Nothing changes until the selection is lifted.
    public init(bitmap: Bitmap, mask: SelectionMask) {
        self.bitmap = bitmap
        self.mask = mask
        before = bitmap.copyPixels()
    }

    /// Starts with pixels from outside the canvas (a paste), floating at `origin`.
    public init(bitmap: Bitmap, pasting pixels: [UInt32], width: Int, height: Int, at origin: PixelPoint, transparent: RGBA?) {
        self.bitmap = bitmap
        mask = SelectionMask(rect: PixelRect(x: origin.x, y: origin.y, width: width, height: height))
        before = bitmap.copyPixels()
        floating = pixels
        base = before
        transparentColor = transparent
        dirty = bitmap.stamp(pixels, mask: mask, skipping: transparent)
    }

    public var isFloating: Bool { floating != nil }

    /// Picks the selected pixels up, leaving `background` in the hole.
    public func lift(background: RGBA, transparent: RGBA?) {
        guard floating == nil else { return }
        transparentColor = transparent
        let pixels = bitmap.pixels(in: mask, outside: background)
        dirty = dirty.union(bitmap.fill(mask, with: background))
        base = bitmap.copyPixels()
        floating = pixels
        dirty = dirty.union(bitmap.stamp(pixels, mask: mask, skipping: transparent))
    }

    /// Moves a lifted selection. Returns the canvas area that changed.
    @discardableResult
    public func move(dx: Int, dy: Int) -> PixelRect {
        guard let floating, let base, dx != 0 || dy != 0 else { return .zero }
        let old = mask.rect
        bitmap.restore(old, from: base)
        mask = mask.offsetBy(dx: dx, dy: dy)
        bitmap.stamp(floating, mask: mask, skipping: transparentColor)
        let changed = old.union(mask.rect).intersection(bitmap.bounds)
        dirty = dirty.union(changed)
        return changed
    }

    /// Changes which color is see-through and redraws a lifted selection in place.
    @discardableResult
    public func setTransparentColor(_ color: RGBA?) -> PixelRect {
        transparentColor = color
        guard let floating, let base else { return .zero }
        bitmap.restore(mask.rect, from: base)
        let changed = bitmap.stamp(floating, mask: mask, skipping: color)
        dirty = dirty.union(changed)
        return changed
    }

    /// The selected pixels over `mask.rect`, with pixels outside a free-form mask set to `outside`.
    public func selectedPixels(outside: RGBA) -> [UInt32] {
        if let floating {
            guard !mask.isRectangular else { return floating }
            var pixels = floating
            for y in 0..<mask.rect.height {
                for x in 0..<mask.rect.width where !mask.covers(localX: x, localY: y) {
                    pixels[y * mask.rect.width + x] = outside.packed
                }
            }
            return pixels
        }
        return bitmap.pixels(in: mask, outside: outside)
    }

    /// Removes the selection: a lifted selection is dropped, otherwise its area is filled
    /// with `background`. Returns the canvas area that changed.
    @discardableResult
    public func erase(background: RGBA) -> PixelRect {
        let changed: PixelRect
        if floating != nil, let base {
            changed = mask.rect.intersection(bitmap.bounds)
            bitmap.restore(changed, from: base)
            floating = nil
            self.base = nil
        } else {
            changed = bitmap.fill(mask, with: background)
        }
        dirty = dirty.union(changed)
        return changed
    }
}
