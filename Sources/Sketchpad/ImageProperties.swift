import AppKit
import PaintCore

/// Paint's Image Properties dialog (Ctrl+E there), shown as an alert sheet.
final class ImagePropertiesForm: NSObject, NSTextFieldDelegate {
    struct Result: Equatable {
        var width: Int
        var height: Int
        var blackAndWhite: Bool
    }

    enum Unit: Int, CaseIterable {
        case inches, centimeters, pixels

        var title: String {
            switch self {
            case .inches: "Inches"
            case .centimeters: "Centimeters"
            case .pixels: "Pixels"
            }
        }
    }

    /// The largest side accepted (this app's limit; it keeps the bitmap under 1.6 GB).
    static let maxSide = 20_000

    let dotsPerInch: Double
    let unitControl = NSSegmentedControl(labels: Unit.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let widthField = NSTextField(string: "")
    let heightField = NSTextField(string: "")
    let colorControl = NSSegmentedControl(labels: ["Black and white", "Color"], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var view = NSView()
    /// The size in pixels. Kept fractional so switching units back and forth does not drift.
    private var pixelWidth: Double
    private var pixelHeight: Double

    init(width: Int, height: Int, dotsPerInch: Double, lastSaved: Date?, sizeOnDisk: Int?) {
        self.dotsPerInch = dotsPerInch
        pixelWidth = Double(width)
        pixelHeight = Double(height)
        super.init()

        unitControl.selectedSegment = Unit.pixels.rawValue
        unitControl.target = self
        unitControl.action = #selector(unitChanged)
        colorControl.selectedSegment = 1
        for field in [widthField, heightField] {
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        let defaultButton = NSButton(title: "Default", target: self, action: #selector(restoreDefaultSize))

        let notAvailable = "Not Available"
        let saved = lastSaved.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? notAvailable
        let disk = sizeOnDisk.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? notAvailable
        let grid = NSGridView(views: [
            [label("Last Saved:"), label(saved)],
            [label("Size on disk:"), label(disk)],
            [label("Resolution:"), label("\(Int(dotsPerInch.rounded())) DPI")],
            [label("Units:"), unitControl],
            [label("Width:"), widthField],
            [label("Height:"), heightField],
            [label("Colors:"), colorControl],
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
        alert.messageText = "Image Properties"
        alert.accessoryView = form.view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
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
        showSize()
    }

    @objc func restoreDefaultSize() {
        pixelWidth = Double(CanvasDocument.newCanvasSize.width)
        pixelHeight = Double(CanvasDocument.newCanvasSize.height)
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
