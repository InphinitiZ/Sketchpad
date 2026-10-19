import AppKit
import PaintCore

enum Tool: Int, CaseIterable {
    case select, freeFormSelect, text, pencil, brush, eraser, fill, picker, magnifier, shape

    var title: String {
        switch self {
        case .select: localized("Rectangular Selection")
        case .freeFormSelect: localized("Free-form Selection")
        case .text: localized("Text")
        case .pencil: localized("Pencil")
        case .brush: localized("Brushes")
        case .eraser: localized("Eraser")
        case .fill: localized("Fill with Color")
        case .picker: localized("Color Picker")
        case .magnifier: localized("Magnifier")
        case .shape: localized("Shapes")
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
        case .line: localized("Line")
        case .curve: localized("Curve")
        case .oval: localized("Oval")
        case .rectangle: localized("Rectangle")
        case .roundedRectangle: localized("Rounded Rectangle")
        case .polygon: localized("Polygon")
        case .triangle: localized("Triangle")
        case .rightTriangle: localized("Right Triangle")
        case .diamond: localized("Diamond")
        case .pentagon: localized("Pentagon")
        case .hexagon: localized("Hexagon")
        case .rightArrow: localized("Right Arrow")
        case .leftArrow: localized("Left Arrow")
        case .upArrow: localized("Up Arrow")
        case .downArrow: localized("Down Arrow")
        case .fourPointStar: localized("Four-point Star")
        case .fivePointStar: localized("Five-point Star")
        case .sixPointStar: localized("Six-point Star")
        case .roundedRectangleCallout: localized("Rounded Rectangular Callout")
        case .ovalCallout: localized("Oval Callout")
        case .cloudCallout: localized("Cloud Callout")
        case .heart: localized("Heart")
        case .lightning: localized("Lightning")
        }
    }
}

extension BrushKind {
    var title: String {
        switch self {
        case .normal: localized("Brush")
        case .calligraphy45: localized("Calligraphy Brush 1")
        case .calligraphy135: localized("Calligraphy Brush 2")
        case .airbrush: localized("Airbrush")
        case .oil: localized("Oil Brush")
        case .crayon: localized("Crayon")
        case .marker: localized("Marker")
        case .naturalPencil: localized("Natural Pencil")
        case .watercolor: localized("Watercolor Brush")
        }
    }

    /// Paint's Size gallery for the brush, in pixels (`CPBApp::AddTools`).
    var sizes: [Int] {
        switch self {
        case .normal: [1, 3, 5, 8]
        case .calligraphy45, .calligraphy135: [3, 5, 8, 10]
        case .airbrush: [4, 8, 16, 24]
        case .naturalPencil: [4, 6, 8, 10]
        case .oil, .crayon, .marker, .watercolor: [8, 16, 30, 40]
        }
    }

    /// The size the brush starts with (`CPBApp::InitializeAttributes`).
    var defaultSize: Int {
        switch self {
        case .normal: 3
        case .calligraphy45, .calligraphy135: 5
        case .airbrush: 8
        case .naturalPencil: 4
        case .oil, .crayon, .marker, .watercolor: 30
        }
    }

    /// Where the chosen size is kept; both calligraphy brushes share one setting, as in Paint.
    fileprivate var sizeKey: String {
        self == .calligraphy45 || self == .calligraphy135 ? "brush.calligraphy" : "brush.\(self)"
    }
}

/// A choice in Paint's Outline or Fill gallery.
enum ShapePaint: CaseIterable {
    case none, solid, crayon, marker, oil, naturalPencil, watercolor

    /// The texture, or `nil` for none and solid color.
    var medium: Medium? {
        switch self {
        case .none, .solid: nil
        case .crayon: .crayon
        case .marker: .marker
        case .oil: .oil
        case .naturalPencil: .naturalPencil
        case .watercolor: .watercolor
        }
    }

    func title(forOutline outline: Bool) -> String {
        switch self {
        case .none: outline ? localized("No outline") : localized("No fill")
        case .solid: localized("Solid color")
        case .crayon: localized("Crayon")
        case .marker: localized("Marker")
        case .oil: localized("Oil")
        case .naturalPencil: localized("Natural pencil")
        case .watercolor: localized("Watercolor")
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
    /// Paint's Outline gallery (drawn in color 1).
    var shapeOutline = ShapePaint.solid { didSet { notify() } }
    /// Paint's Fill gallery (drawn in color 2).
    var shapeFill = ShapePaint.none { didSet { notify() } }
    var brushKind: BrushKind = .normal { didSet { notify() } }
    /// When on, pixels of color 2 in a moved or pasted selection are see-through.
    var transparentSelection = false { didSet { notify() } }
    var textStyle = TextStyle() { didSet { notify() } }

    private var sizes: [String: Int] = [:]
    private var observers: [() -> Void] = []

    /// Paint's Size gallery for the current tool, in pixels (`CPBApp::AddTools`); empty when
    /// size does not apply.
    var sizeOptions: [Int] {
        switch tool {
        case .pencil: [1, 2, 3, 4]
        case .eraser: [4, 6, 8, 10]
        case .shape: [1, 3, 5, 8]
        case .brush: brushKind.sizes
        case .select, .freeFormSelect, .text, .fill, .picker, .magnifier: []
        }
    }

    /// The size each tool starts with (`CPBApp::InitializeAttributes` and the tool constructors).
    private var defaultSize: Int {
        switch tool {
        case .eraser: 8
        case .shape: 5
        case .brush: brushKind.defaultSize
        case .pencil, .select, .freeFormSelect, .text, .fill, .picker, .magnifier: 1
        }
    }

    private var sizeKey: String { tool == .brush ? brushKind.sizeKey : "\(tool)" }

    var size: Int {
        get { sizes[sizeKey] ?? defaultSize }
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

    /// Names for the swatches' tooltips and VoiceOver, in the order of `colors`.
    static let names: [String] = [
        localized("Black"), localized("Gray-50%"), localized("Dark red"), localized("Red"), localized("Orange"),
        localized("Yellow"), localized("Green"), localized("Turquoise"), localized("Indigo"), localized("Purple"),
        localized("White"), localized("Gray-25%"), localized("Brown"), localized("Rose"), localized("Gold"),
        localized("Light yellow"), localized("Lime"), localized("Light turquoise"), localized("Blue-gray"), localized("Lavender"),
    ]

    /// The palette name of `color`, or its components for any other color.
    static func name(of color: RGBA) -> String {
        if let index = colors.firstIndex(of: color) { return names[index] }
        return localized(format: "Red %ld, Green %ld, Blue %ld", Int(color.r), Int(color.g), Int(color.b))
    }
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
