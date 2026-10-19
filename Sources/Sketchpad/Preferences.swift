import AppKit
import PaintCore

/// Settings kept between runs, after the values Paint keeps under its registry key
/// `HKCU\…\Applets\Paint` (`CPBApp::LoadProfileSettings`): the View options, the measuring unit,
/// the text tool's font, and the size of the last picture for new ones.
enum Preferences {
    /// The app's settings; anywhere else (the test runner) a scratch domain, emptied at launch,
    /// so tests never depend on or change the user's settings. A test can give itself a
    /// private store with `Preferences.$store.withValue(…)`.
    @TaskLocal static var store: UserDefaults = defaultStore

    private static let defaultStore: UserDefaults = {
        guard Bundle.main.bundleIdentifier != "dev.local.Sketchpad" else { return .standard }
        let name = "dev.local.Sketchpad.scratch"
        let scratch = UserDefaults(suiteName: name)!
        scratch.removePersistentDomain(forName: name)
        return scratch
    }()

    enum Unit: Int, CaseIterable {
        case inches, centimeters, pixels

        var title: String {
            switch self {
            case .inches: localized("Inches")
            case .centimeters: localized("Centimeters")
            case .pixels: localized("Pixels")
            }
        }

        var abbreviation: String {
            switch self {
            case .inches: localized("in")
            case .centimeters: localized("cm")
            case .pixels: localized("px")
            }
        }

        /// Pixels in one unit at `dotsPerInch`.
        func pixels(at dotsPerInch: Double) -> Double {
            switch self {
            case .inches: dotsPerInch
            case .centimeters: dotsPerInch / 2.54
            case .pixels: 1
            }
        }

        /// A pixel measure in this unit, as Paint's status bar shows it.
        func format(_ pixels: Int, at dotsPerInch: Double) -> String {
            self == .pixels ? String(pixels) : String(format: "%.2f", Double(pixels) / self.pixels(at: dotsPerInch))
        }
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }

    static var unit: Unit {
        // Pixels until a unit is chosen (a missing key reads as 0, which is inches).
        get { store.object(forKey: "UnitSetting") == nil ? .pixels : Unit(rawValue: store.integer(forKey: "UnitSetting")) ?? .pixels }
        set { store.set(newValue.rawValue, forKey: "UnitSetting") }
    }

    static var showRulers: Bool {
        get { bool("ShowRulers", default: false) }
        set { store.set(newValue, forKey: "ShowRulers") }
    }

    static var showGrid: Bool {
        get { bool("ShowGrid", default: false) }
        set { store.set(newValue, forKey: "ShowGrid") }
    }

    static var showStatusBar: Bool {
        get { bool("ShowStatusBar", default: true) }
        set { store.set(newValue, forKey: "ShowStatusBar") }
    }

    static var showThumbnail: Bool {
        get { bool("ShowThumbnail", default: false) }
        set { store.set(newValue, forKey: "ShowThumbnail") }
    }

    /// The text tool's font and effects (Paint's `Text` section).
    static var textStyle: TextStyle {
        get {
            var style = TextStyle()
            if let family = store.string(forKey: "TypeFaceName"), NSFontManager.shared.availableFontFamilies.contains(family) { style.family = family }
            let points = store.double(forKey: "PointSize")
            if points > 0 { style.points = CGFloat(points) }
            style.bold = store.bool(forKey: "Bold")
            style.italic = store.bool(forKey: "Italic")
            style.underline = store.bool(forKey: "Underline")
            style.strikethrough = store.bool(forKey: "Strikeout")
            style.opaque = store.bool(forKey: "TextOpaque")
            return style
        }
        set {
            store.set(newValue.family, forKey: "TypeFaceName")
            store.set(Double(newValue.points), forKey: "PointSize")
            store.set(newValue.bold, forKey: "Bold")
            store.set(newValue.italic, forKey: "Italic")
            store.set(newValue.underline, forKey: "Underline")
            store.set(newValue.strikethrough, forKey: "Strikeout")
            store.set(newValue.opaque, forKey: "TextOpaque")
        }
    }

    /// The size for new pictures: the last picture's, if neither side is over 5000 (Paint's
    /// `BMPWidth`/`BMPHeight`), else the default.
    static var newPictureSize: (width: Int, height: Int) {
        get {
            let width = store.integer(forKey: "BMPWidth"), height = store.integer(forKey: "BMPHeight")
            guard (1...5000).contains(width), (1...5000).contains(height) else { return CanvasDocument.defaultCanvasSize }
            return (width, height)
        }
        set {
            store.set(newValue.width, forKey: "BMPWidth")
            store.set(newValue.height, forKey: "BMPHeight")
        }
    }
}
