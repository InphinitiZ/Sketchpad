import AppKit
import PaintCore

/// Paint's Image Properties dialog (Ctrl+E there), shown as an alert sheet.
final class ImagePropertiesForm: NSObject, NSTextFieldDelegate {
    struct Result: Equatable {
        var width: Int
        var height: Int
        var blackAndWhite: Bool
    }

    typealias Unit = Preferences.Unit

    /// Paint's fields take five digits.
    static let maxSide = 99_999

    let dotsPerInch: Double
    let unitControl = NSSegmentedControl(labels: Unit.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let widthField = NSTextField(string: "")
    let heightField = NSTextField(string: "")
    let colorControl = NSSegmentedControl(labels: [localized("Black and white"), localized("Color")], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var view = NSView()
    /// The size in pixels. Kept fractional so switching units back and forth does not drift.
    private var pixelWidth: Double
    private var pixelHeight: Double

    init(width: Int, height: Int, dotsPerInch: Double, lastSaved: Date?, sizeOnDisk: Int?) {
        self.dotsPerInch = dotsPerInch
        pixelWidth = Double(width)
        pixelHeight = Double(height)
        super.init()

        // Paint remembers the unit (UnitSetting) and uses it for the rulers and status bar too.
        unitControl.selectedSegment = Preferences.unit.rawValue
        unitControl.target = self
        unitControl.action = #selector(unitChanged)
        colorControl.selectedSegment = 1
        for field in [widthField, heightField] {
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        let defaultButton = NSButton(title: localized("Default"), target: self, action: #selector(restoreDefaultSize))

        let notAvailable = localized("Not Available")
        let saved = lastSaved.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? notAvailable
        let disk = sizeOnDisk.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? notAvailable
        let grid = NSGridView(views: [
            [label(localized("Last Saved:")), label(saved)],
            [label(localized("Size on disk:")), label(disk)],
            [label(localized("Resolution:")), label(localized(format: "%ld DPI", Int(dotsPerInch.rounded())))],
            [label(localized("Units:")), unitControl],
            [label(localized("Width:")), widthField],
            [label(localized("Height:")), heightField],
            [label(localized("Colors:")), colorControl],
            [NSGridCell.emptyContentView, defaultButton],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 3).topPadding = 8
        grid.frame.size = grid.fittingSize
        view = grid
        showSize()
    }

    var unit: Unit { Unit(rawValue: unitControl.selectedSegment) ?? .pixels }

    var result: Result {
        func clamp(_ value: Double) -> Int { min(max(Int(value.rounded()), 1), Self.maxSide) }
        return Result(width: clamp(pixelWidth), height: clamp(pixelHeight), blackAndWhite: colorControl.selectedSegment == 0)
    }

    static func run(for document: CanvasDocument, on window: NSWindow, completion: @escaping (Result) -> Void) {
        let size = (try? document.fileURL?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let form = ImagePropertiesForm(
            width: document.bitmap.width,
            height: document.bitmap.height,
            dotsPerInch: document.dotsPerInch,
            lastSaved: document.fileModificationDate,
            sizeOnDisk: size
        )
        let alert = NSAlert()
        alert.messageText = localized("Image Properties")
        alert.accessoryView = form.view
        alert.addButton(withTitle: localized("OK"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(form.result) }
        }
    }

    // MARK: - Units

    /// Pixels in one of `unit`.
    private func pixels(per unit: Unit) -> Double {
        switch unit {
        case .inches: dotsPerInch
        case .centimeters: dotsPerInch / 2.54
        case .pixels: 1
        }
    }

    private func showSize() {
        let factor = pixels(per: unit)
        func format(_ value: Double) -> String {
            unit == .pixels ? String(Int(value.rounded())) : String(format: "%.2f", value)
        }
        widthField.stringValue = format(pixelWidth / factor)
        heightField.stringValue = format(pixelHeight / factor)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) else { return }
        let pixels = value * pixels(per: unit)
        if field === widthField { pixelWidth = pixels } else if field === heightField { pixelHeight = pixels }
    }

    @objc func unitChanged() {
        Preferences.unit = unit
        showSize()
    }

    @objc func restoreDefaultSize() {
        pixelWidth = Double(CanvasDocument.defaultCanvasSize.width)
        pixelHeight = Double(CanvasDocument.defaultCanvasSize.height)
        showSize()
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }
}

/// Prints the picture at its resolution: a pixel is 72/dpi points.
final class PrintView: NSView {
    private let image: CGImage

    init(image: CGImage, dotsPerInch: Double) {
        self.image = image
        let scale = 72 / dotsPerInch
        super.init(frame: NSRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }
}

/// Paint's Page Setup extras beside the system's paper and scale settings: centering on the
/// page, and fitting the picture to a number of pages across and down.
final class PageSetupAccessory: NSViewController, NSPrintPanelAccessorizing {
    static let fitWideKey = NSPrintInfo.AttributeKey("SketchpadFitPagesWide")
    static let fitTallKey = NSPrintInfo.AttributeKey("SketchpadFitPagesTall")

    private let centerHorizontally = NSButton(checkboxWithTitle: localized("Center horizontally"), target: nil, action: nil)
    private let centerVertically = NSButton(checkboxWithTitle: localized("Center vertically"), target: nil, action: nil)
    private let fit = NSButton(checkboxWithTitle: localized("Fit to"), target: nil, action: nil)
    private let wide = NSTextField(string: "1")
    private let tall = NSTextField(string: "1")

    private var info: NSPrintInfo? { representedObject as? NSPrintInfo }

    override func loadView() {
        for control in [centerHorizontally, centerVertically, fit] {
            control.target = self
            control.action = #selector(changed)
        }
        for field in [wide, tall] {
            field.target = self
            field.action = #selector(changed)
            field.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        let fitRow = NSStackView(views: [fit, wide, NSTextField(labelWithString: localized("pages wide by")), tall, NSTextField(labelWithString: localized("tall"))])
        let stack = NSStackView(views: [
            NSTextField(labelWithString: localized("Centering:")), centerHorizontally, centerVertically,
            NSTextField(labelWithString: localized("Scaling:")), fitRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        stack.frame.size = stack.fittingSize
        view = stack
    }

    override var representedObject: Any? {
        didSet { showSettings() }
    }

    private func showSettings() {
        guard let info, isViewLoaded else { return }
        centerHorizontally.state = info.isHorizontallyCentered ? .on : .off
        centerVertically.state = info.isVerticallyCentered ? .on : .off
        let pages = Self.fitPages(of: info)
        fit.state = pages == nil ? .off : .on
        wide.integerValue = pages?.wide ?? 1
        tall.integerValue = pages?.tall ?? 1
        wide.isEnabled = pages != nil
        tall.isEnabled = pages != nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showSettings()
    }

    @objc private func changed() {
        guard let info else { return }
        info.isHorizontallyCentered = centerHorizontally.state == .on
        info.isVerticallyCentered = centerVertically.state == .on
        let on = fit.state == .on
        info.dictionary()[Self.fitWideKey] = on ? max(1, wide.integerValue) : 0
        info.dictionary()[Self.fitTallKey] = on ? max(1, tall.integerValue) : 0
        wide.isEnabled = on
        tall.isEnabled = on
    }

    /// The Fit To setting, or `nil` when the picture prints at its scale.
    static func fitPages(of info: NSPrintInfo) -> (wide: Int, tall: Int)? {
        let wide = (info.dictionary()[fitWideKey] as? Int) ?? 0, tall = (info.dictionary()[fitTallKey] as? Int) ?? 0
        return wide > 0 && tall > 0 ? (wide, tall) : nil
    }

    /// The scale that makes a picture of `size` points span the Fit To pages: their area inside
    /// the margins, which is what each printed page shows.
    static func fitScale(for size: NSSize, info: NSPrintInfo) -> CGFloat? {
        guard let pages = fitPages(of: info), size.width > 0, size.height > 0 else { return nil }
        let page = printableSize(of: info)
        return min(page.width * CGFloat(pages.wide) / size.width, page.height * CGFloat(pages.tall) / size.height)
    }

    /// The paper inside the margins.
    static func printableSize(of info: NSPrintInfo) -> NSSize {
        NSSize(width: max(1, info.paperSize.width - info.leftMargin - info.rightMargin),
               height: max(1, info.paperSize.height - info.topMargin - info.bottomMargin))
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] { [] }
    func keyPathsForValuesAffectingPreview() -> Set<String> { [] }
}
