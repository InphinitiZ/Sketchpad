import AppKit
import PaintCore

enum Tool: Int, CaseIterable {
    case select, freeFormSelect, text, pencil, brush, eraser, fill, picker, magnifier, shape

    var title: String {
        switch self {
        case .select: "Rectangular Selection"
        case .freeFormSelect: "Free-form Selection"
        case .text: "Text"
        case .pencil: "Pencil"
        case .brush: "Brushes"
        case .eraser: "Eraser"
        case .fill: "Fill with Color"
        case .picker: "Color Picker"
        case .magnifier: "Magnifier"
        case .shape: "Shapes"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "rectangle.dashed"
        case .freeFormSelect: "lasso"
        case .text: "textformat"
        case .pencil: "pencil"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .fill: "drop.fill"
        case .picker: "eyedropper"
        case .magnifier: "magnifyingglass"
        case .shape: "square.on.circle"
        }
    }

    /// Paint's single-letter tool keys (from the ribbon tooltips).
    var shortcut: Character? {
        switch self {
        case .select: "s"
        case .text: "t"
        case .pencil: "p"
        case .eraser: "e"
        case .fill: "b"
        case .picker: "i"
        case .magnifier: "z"
        case .freeFormSelect, .brush, .shape: nil
        }
    }

    var isSelection: Bool { self == .select || self == .freeFormSelect }
}

extension ShapeKind {
    var title: String {
        switch self {
        case .line: "Line"
        case .curve: "Curve"
        case .oval: "Oval"
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .polygon: "Polygon"
        case .triangle: "Triangle"
        case .rightTriangle: "Right Triangle"
        case .diamond: "Diamond"
        case .pentagon: "Pentagon"
        case .hexagon: "Hexagon"
        case .rightArrow: "Right Arrow"
        case .leftArrow: "Left Arrow"
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .fourPointStar: "Four-point Star"
        case .fivePointStar: "Five-point Star"
        case .sixPointStar: "Six-point Star"
        case .roundedRectangleCallout: "Rounded Rectangular Callout"
        case .ovalCallout: "Oval Callout"
        case .cloudCallout: "Cloud Callout"
        case .heart: "Heart"
        case .lightning: "Lightning"
        }
    }
}

extension BrushKind {
    var title: String {
        switch self {
        case .normal: "Brush"
        case .calligraphy45: "Calligraphy Brush 1"
        case .calligraphy135: "Calligraphy Brush 2"
        case .airbrush: "Airbrush"
        }
    }
}

struct TextStyle: Equatable {
    var family = "Helvetica"
    /// Size in points. Paint renders text at 96 dpi, so one point is 4/3 of a canvas pixel.
    var points: CGFloat = 12
    var bold = false
    var italic = false
    var underline = false
    /// Paint's "Opaque" text background fills the box with color 2.
    var opaque = false

    static let pointSizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    var pixelSize: CGFloat { points * 4 / 3 }

    var font: NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: pixelSize)
            ?? NSFont.systemFont(ofSize: pixelSize)
    }
}

/// Tool and color settings for one window. Views register with `observe` to refresh.
final class EditorState {
    var tool: Tool = .pencil {
        didSet {
            guard tool != oldValue else { return }
            previousTool = oldValue
            notify()
        }
    }

    /// The tool to return to after a one-shot tool such as the color picker.
    private(set) var previousTool: Tool = .pencil

    var primary: RGBA = .black { didSet { notify() } }
    var secondary: RGBA = .white { didSet { notify() } }
    var shapeKind: ShapeKind = .line { didSet { notify() } }
    /// Paint's Outline gallery, reduced to "No outline" and "Solid color" until textures exist.
    var shapeOutline = true { didSet { notify() } }
    /// Paint's Fill gallery: "No fill" or "Solid color" (color 2).
    var shapeFill = false { didSet { notify() } }
    var brushKind: BrushKind = .normal { didSet { notify() } }
    /// When on, pixels of color 2 in a moved or pasted selection are see-through.
    var transparentSelection = false { didSet { notify() } }
    var textStyle = TextStyle() { didSet { notify() } }

    private var sizes: [String: Int] = [:]
    private var observers: [() -> Void] = []

    /// Size choices for the current tool, in pixels; empty when size does not apply. Pencil,
    /// eraser and shape sizes are Paint's; the brush sizes are this app's choice.
    var sizeOptions: [Int] {
        switch tool {
        case .pencil: [1, 2, 3, 4]
        case .eraser: [4, 6, 8, 10]
        case .shape: [1, 3, 5, 8]
        case .brush: brushKind == .airbrush ? [8, 16, 24, 30] : [1, 3, 5, 8]
        case .select, .freeFormSelect, .text, .fill, .picker, .magnifier: []
        }
    }

    private var sizeKey: String { tool == .brush ? "brush.\(brushKind)" : "\(tool)" }

    var size: Int {
        get { sizes[sizeKey] ?? sizeOptions.first ?? 1 }
        set {
            sizes[sizeKey] = newValue
            notify()
        }
    }

    /// The see-through color for selections under the current settings.
    var selectionTransparentColor: RGBA? { transparentSelection ? secondary : nil }

    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    private func notify() {
        observers.forEach { $0() }
    }
}

/// The default 20-color palette from Windows 7 Paint.
enum ClassicPalette {
    static let colors: [RGBA] = [
        RGBA(0, 0, 0), RGBA(127, 127, 127), RGBA(136, 0, 21), RGBA(237, 28, 36), RGBA(255, 127, 39),
        RGBA(255, 242, 0), RGBA(34, 177, 76), RGBA(0, 162, 232), RGBA(63, 72, 204), RGBA(163, 73, 164),
        RGBA(255, 255, 255), RGBA(195, 195, 195), RGBA(185, 122, 87), RGBA(255, 174, 201), RGBA(255, 201, 14),
        RGBA(239, 228, 176), RGBA(181, 230, 29), RGBA(153, 217, 234), RGBA(112, 146, 190), RGBA(200, 191, 231),
    ]
}

extension RGBA {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
