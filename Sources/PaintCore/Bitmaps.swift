import Foundation

/// Paint's four BMP flavors in Save As: Monochrome, 16 Color, 256 Color and 24-bit Bitmap.
public enum BitmapDepth: Int, CaseIterable, Sendable {
    case monochrome = 1
    case sixteenColors = 4
    case twoHundredFiftySixColors = 8
    case trueColor = 24

    /// How many colors a file of this depth can hold.
    public var colorLimit: Int {
        switch self {
        case .monochrome: 2
        case .sixteenColors: 16
        case .twoHundredFiftySixColors: 256
        case .trueColor: 1 << 24
        }
    }

    /// The fixed palettes Windows uses: black and white, and the 16 VGA colors.
    static let monochromePalette: [RGBA] = [.black, .white]
    static let vgaPalette: [RGBA] = [
        RGBA(0, 0, 0), RGBA(128, 0, 0), RGBA(0, 128, 0), RGBA(128, 128, 0),
        RGBA(0, 0, 128), RGBA(128, 0, 128), RGBA(0, 128, 128), RGBA(192, 192, 192),
        RGBA(128, 128, 128), RGBA(255, 0, 0), RGBA(0, 255, 0), RGBA(255, 255, 0),
        RGBA(0, 0, 255), RGBA(255, 0, 255), RGBA(0, 255, 255), RGBA(255, 255, 255),
    ]

    /// A general 256-color palette for pictures with more colors: the 6×6×6 color cube, the
    /// VGA colors and grays.
    static let generalPalette: [RGBA] = {
        var colors: [RGBA] = []
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 { colors.append(RGBA(UInt8(r * 51), UInt8(g * 51), UInt8(b * 51))) } } }
        for color in vgaPalette where !colors.contains(color) { colors.append(color) }
        var level = 8
        while colors.count < 256 {
            let gray = RGBA(UInt8(level), UInt8(level), UInt8(level))
            if !colors.contains(gray) { colors.append(gray) }
            level += 6
        }
        return Array(colors.prefix(256))
    }()
}

extension PixelGrid {
    /// The number of distinct colors, counting no further than `limit + 1`.
    public func colorCount(upTo limit: Int) -> Int {
        var seen = Set<UInt32>()
        for pixel in pixels {
            seen.insert(pixel | 0xFF00_0000)
            if seen.count > limit { break }
        }
        return seen.count
    }

    /// Whether saving at `depth` would lose colors (Paint's "the color quality might be reduced").
    public func losesColors(at depth: BitmapDepth) -> Bool {
        guard depth != .trueColor else { return false }
        if depth == .monochrome {
            return pixels.contains { let c = $0 | 0xFF00_0000; return c != RGBA.black.packed && c != RGBA.white.packed }
        }
        return colorCount(upTo: depth.colorLimit) > depth.colorLimit
    }
}

extension ImageCodec {
    /// Writes `grid` as an uncompressed Windows bitmap of `depth`, mapping each pixel to the
    /// nearest palette color when the depth holds fewer colors than the picture has.
    public static func encodeBMP(_ grid: PixelGrid, depth: BitmapDepth, dotsPerInch: Double = defaultDotsPerInch) -> Data {
        let bits = depth.rawValue
        var palette: [RGBA] = []
        switch depth {
        case .monochrome:
            palette = BitmapDepth.monochromePalette
        case .sixteenColors:
            palette = BitmapDepth.vgaPalette
        case .twoHundredFiftySixColors:
            // The picture's own colors if they fit, else a general palette.
            var own: [UInt32] = []
            var seen = Set<UInt32>()
            for pixel in grid.pixels where seen.insert(pixel | 0xFF00_0000).inserted {
                own.append(pixel | 0xFF00_0000)
                if own.count > 256 { break }
            }
            palette = own.count <= 256 ? own.map { RGBA(packed: $0) } : BitmapDepth.generalPalette
        case .trueColor:
            break
        }

        let rowBytes = ((grid.width * bits + 31) / 32) * 4
        let paletteBytes = palette.count * 4
        let pixelOffset = 14 + 40 + paletteBytes
        let fileSize = pixelOffset + rowBytes * grid.height
        var data = Data(capacity: fileSize)
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }

        // BITMAPFILEHEADER
        data.append(contentsOf: [0x42, 0x4D])
        u32(fileSize); u16(0); u16(0); u32(pixelOffset)
        // BITMAPINFOHEADER; rows run bottom-up.
        let pixelsPerMeter = Int((dotsPerInch / 0.0254).rounded())
        u32(40); u32(grid.width); u32(grid.height); u16(1); u16(bits); u32(0)
        u32(rowBytes * grid.height); u32(pixelsPerMeter); u32(pixelsPerMeter); u32(palette.count); u32(0)
        for color in palette { data.append(contentsOf: [color.b, color.g, color.r, 0]) }

        var nearest: [UInt32: UInt8] = [:]
        func index(of pixel: UInt32) -> UInt8 {
            let key = pixel | 0xFF00_0000
            if let cached = nearest[key] { return cached }
            let c = RGBA(packed: key)
            var best = 0, bestDistance = Int.max
            for (i, p) in palette.enumerated() {
                let dr = Int(c.r) - Int(p.r), dg = Int(c.g) - Int(p.g), db = Int(c.b) - Int(p.b)
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance { best = i; bestDistance = distance }
            }
            nearest[key] = UInt8(best)
            return UInt8(best)
        }

        var row = [UInt8](repeating: 0, count: rowBytes)
        for y in stride(from: grid.height - 1, through: 0, by: -1) {
            for i in row.indices { row[i] = 0 }
            for x in 0..<grid.width {
                let pixel = grid[x, y]
                switch depth {
                case .trueColor:
                    let c = RGBA(packed: pixel)
                    row[x * 3] = c.b; row[x * 3 + 1] = c.g; row[x * 3 + 2] = c.r
                case .twoHundredFiftySixColors:
                    row[x] = index(of: pixel)
                case .sixteenColors:
                    row[x / 2] |= index(of: pixel) << (x % 2 == 0 ? 4 : 0)
                case .monochrome:
                    if index(of: pixel) == 1 { row[x / 8] |= 0x80 >> (x % 8) }
                }
            }
            data.append(contentsOf: row)
        }
        return data
    }
}
