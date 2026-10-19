import AppKit

/// The rules of Paint's gridlines (`CImgWnd::GetInterGridLineSeperation` and `DrawGrid`).
enum Gridlines {
    /// The distance between lines, in `unit`s, for a zoom. Closer in, the grid gets finer, down
    /// to every pixel from 400%. Inches and centimeters go back to 1 from 400%, as in Paint.
    static func spacing(zoom: CGFloat, unit: Preferences.Unit) -> Double {
        // Thresholds: 400%, 200%, 100%, 50%, 25%, 10%, below.
        let table: [Double]
        switch unit {
        case .pixels: table = [1, 5, 10, 20, 50, 100, 200]
        case .inches: table = [1, 0.1, 0.25, 0.5, 1, 2, 5]
        case .centimeters: table = [1, 0.25, 0.5, 1, 2, 5, 10]
        }
        let thresholds: [CGFloat] = [4, 2, 1, 0.5, 0.25, 0.1]
        return table[thresholds.firstIndex { zoom >= $0 } ?? thresholds.count]
    }

    /// The spacing in picture pixels, using the picture's resolution for inches and centimeters.
    static func step(zoom: CGFloat, unit: Preferences.Unit, dotsPerInch: Double) -> Double {
        spacing(zoom: zoom, unit: unit) * unit.pixels(at: dotsPerInch)
    }

    /// The two colors of the checkered dots: opaque grays (#808080 and #C0C0C0) from 400%,
    /// translucent black and #E8E8E8 (50% and 25% opaque) below.
    static func colors(zoom: CGFloat) -> (CGColor, CGColor) {
        if zoom >= 4 {
            return (CGColor(srgbRed: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1),
                    CGColor(srgbRed: 0xC0 / 255, green: 0xC0 / 255, blue: 0xC0 / 255, alpha: 1))
        }
        return (CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5),
                CGColor(srgbRed: 0xE8 / 255, green: 0xE8 / 255, blue: 0xE8 / 255, alpha: 0.25))
    }
}
