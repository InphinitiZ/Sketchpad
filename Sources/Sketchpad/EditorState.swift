import AppKit
import PaintCore

enum Tool: Int, CaseIterable {
    case pencil, eraser, fill, picker, magnifier, line, rectangle, ellipse

    var title: String {
        switch self {
        case .pencil: "Pencil"
        case .eraser: "Eraser"
        case .fill: "Fill with Color"
        case .picker: "Color Picker"
        case .magnifier: "Magnifier"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Oval"
        }
    }

    var symbolName: String {
        switch self {
        case .pencil: "pencil"
        case .eraser: "eraser"
        case .fill: "drop.fill"
        case .picker: "eyedropper"
        case .magnifier: "magnifyingglass"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }

    /// Paint's single-letter tool keys (from the ribbon tooltips).
    var shortcut: Character? {
        switch self {
        case .pencil: "p"
        case .eraser: "e"
        case .fill: "b"
        case .picker: "i"
        case .magnifier: "z"
        case .line, .rectangle, .ellipse: nil
        }
    }

    /// Size choices offered for the tool, in pixels; empty when size does not apply.
    var sizeOptions: [Int] {
        switch self {
        case .pencil: [1, 2, 3, 4]
        case .eraser: [4, 6, 8, 10]
        case .line, .rectangle, .ellipse: [1, 3, 5, 8]
        case .fill, .picker, .magnifier: []
        }
    }

    var shapeKind: ShapeKind? {
        switch self {
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        default: nil
        }
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
    var fillsShapes = false { didSet { notify() } }

    private var sizes: [Tool: Int] = [:]
    private var observers: [() -> Void] = []

    var size: Int {
        get { sizes[tool] ?? tool.sizeOptions.first ?? 1 }
        set {
            sizes[tool] = newValue
            notify()
        }
    }

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
