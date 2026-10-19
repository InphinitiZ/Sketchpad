import CoreGraphics

/// An RGBA8 raster with a top-left origin.
///
/// Pixels can be read and written directly, and `context` is flipped so Core Graphics
/// drawing uses the same coordinates: pixel (x, y) covers the unit square at (x, y).
public final class Bitmap {
    public let width: Int
    public let height: Int
    public let context: CGContext
    let storage: UnsafeMutablePointer<UInt32>

    public init(width: Int, height: Int, fill: RGBA = .white) {
        precondition(width > 0 && height > 0, "Bitmaps must be at least one pixel on a side")
        self.width = width
        self.height = height
        storage = .allocate(capacity: width * height)
        storage.initialize(repeating: fill.packed, count: width * height)
        guard let context = CGContext(
            data: storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            fatalError("Could not create a \(width)×\(height) bitmap context")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        self.context = context
    }

    /// Copies `image` onto a canvas of the same size. Transparency is flattened onto `background`.
    public convenience init(image: CGImage, background: RGBA = .white) {
        self.init(width: image.width, height: image.height, fill: background)
        context.saveGState()
        // Undo the flip for this draw so the image lands upright.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    /// A canvas holding `pixels`, row-major, `width * height` long.
    public convenience init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        self.init(width: width, height: height)
        pixels.withUnsafeBufferPointer { storage.update(from: $0.baseAddress!, count: pixels.count) }
    }

    deinit {
        storage.deallocate()
    }

    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    public func contains(_ p: PixelPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < width && p.y < height
    }

    public subscript(p: PixelPoint) -> RGBA {
        get {
            precondition(contains(p))
            return RGBA(packed: storage[p.y * width + p.x])
        }
        set {
            precondition(contains(p))
            storage[p.y * width + p.x] = newValue.packed
        }
    }

    public func makeImage() -> CGImage? {
        context.makeImage()
    }
}

/// The pixels of one rectangle, used to undo and redo an edit.
public struct RegionSnapshot: Sendable {
    public let rect: PixelRect
    let pixels: [UInt32]
}

extension Bitmap {
    /// A full copy of the pixel buffer, kept as the "before" image while a stroke is in progress.
    public func copyPixels() -> [UInt32] {
        Array(UnsafeBufferPointer(start: storage, count: width * height))
    }

    public func snapshot(_ rect: PixelRect) -> RegionSnapshot {
        snapshot(rect, from: UnsafeBufferPointer(start: storage, count: width * height))
    }

    /// The pixels of `rect` as they were in `pixels`, a buffer from `copyPixels()`.
    public func snapshot(_ rect: PixelRect, from pixels: [UInt32]) -> RegionSnapshot {
        pixels.withUnsafeBufferPointer { snapshot(rect, from: $0) }
    }

    public func restore(_ snapshot: RegionSnapshot) {
        let rect = snapshot.rect
        snapshot.pixels.withUnsafeBufferPointer { source in
            for row in 0..<rect.height {
                (storage + (rect.y + row) * width + rect.x)
                    .update(from: source.baseAddress! + row * rect.width, count: rect.width)
            }
        }
    }

    /// Copies `rect` back from `pixels`, a buffer from `copyPixels()`.
    public func restore(_ rect: PixelRect, from pixels: [UInt32]) {
        let rect = rect.intersection(bounds)
        guard !rect.isEmpty else { return }
        pixels.withUnsafeBufferPointer { source in
            for y in rect.y..<rect.maxY {
                let offset = y * width + rect.x
                (storage + offset).update(from: source.baseAddress! + offset, count: rect.width)
            }
        }
    }

    private func snapshot(_ rect: PixelRect, from source: UnsafeBufferPointer<UInt32>) -> RegionSnapshot {
        let rect = rect.intersection(bounds)
        var pixels: [UInt32] = []
        pixels.reserveCapacity(rect.width * rect.height)
        for y in rect.y..<rect.maxY {
            let start = y * width + rect.x
            pixels.append(contentsOf: source[start..<start + rect.width])
        }
        return RegionSnapshot(rect: rect, pixels: pixels)
    }
}
