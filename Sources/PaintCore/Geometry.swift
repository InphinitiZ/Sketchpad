import CoreGraphics

/// 8-bit sRGB color. Memory order is R, G, B, A, matching `Bitmap`'s pixel layout.
public struct RGBA: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(255, 255, 255)

    /// The pixel as a little-endian `UInt32` read of its R, G, B, A bytes.
    public var packed: UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
    }

    public init(packed: UInt32) {
        self.init(UInt8(packed & 0xFF), UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF), UInt8(packed >> 24))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

public struct PixelPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Integer rectangle in pixel coordinates (top-left origin, `maxX`/`maxY` exclusive).
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The smallest rectangle containing both pixels, inclusive.
    public init(enclosing a: PixelPoint, _ b: PixelPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
    }

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(x, other.x), y0 = min(y, other.y)
        return PixelRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .zero
    }

    /// Shrinks the rectangle by `dx`/`dy` on each side; negative values grow it.
    public func insetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}
