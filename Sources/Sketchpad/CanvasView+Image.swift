import AppKit
import PaintCore

/// Image menu commands. Like Paint, each acts on the selection if there is one and on the
/// whole picture otherwise.
extension CanvasView {
    @objc func rotateRight(_ sender: Any?) {
        applyTransforms([.rotate(.clockwise)], actionName: localized("Rotate"))
    }

    @objc func rotateLeft(_ sender: Any?) {
        applyTransforms([.rotate(.counterclockwise)], actionName: localized("Rotate"))
    }

    @objc func rotateHalfTurn(_ sender: Any?) {
        applyTransforms([.rotate(.halfTurn)], actionName: localized("Rotate"))
    }

    @objc func flipHorizontal(_ sender: Any?) {
        applyTransforms([.flipHorizontal], actionName: localized("Flip"))
    }

    @objc func flipVertical(_ sender: Any?) {
        applyTransforms([.flipVertical], actionName: localized("Flip"))
    }

    /// Paint's Invert Color (Ctrl+Shift+I): the selection if there is one, else the picture.
    @objc func invertColor(_ sender: Any?) {
        applyTransforms([.invertColors], actionName: localized("Invert Color"))
    }

    /// Paint's Resize and Skew dialog (Ctrl+W there; ⌘W is Close on the Mac).
    @objc func resizeAndSkew(_ sender: Any?) {
        guard let window else { return }
        commitText()
        let size = selection?.mask.rect ?? document.bitmap.bounds
        ResizeSkewForm.run(width: size.width, height: size.height, on: window) { [weak self] result in
            self?.applyTransforms(result.transforms(from: size.width, size.height), actionName: localized("Resize and Skew"))
        }
    }

    @objc func showImageProperties(_ sender: Any?) {
        guard let window else { return }
        finishInteractions()
        ImagePropertiesForm.run(for: document, on: window) { [weak self] result in
            guard let self else { return }
            (self.window?.windowController as? CanvasWindowController)?.applyUnit()
            guard result.blackAndWhite, self.document.bitmap.grid.losesColors(at: .monochrome) else {
                self.applyImageProperties(result)
                return
            }
            // Paint asks before throwing the colors away.
            let alert = NSAlert()
            alert.messageText = localized("Converting to black and white loses the picture's colors.")
            alert.informativeText = localized("Do you want to continue?")
            alert.addButton(withTitle: localized("Continue"))
            alert.addButton(withTitle: localized("Cancel"))
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { self.applyImageProperties(result) }
            }
        }
    }

    /// Changes the canvas size (new area in color 2) and/or converts to black and white,
    /// as one undo step.
    func applyImageProperties(_ result: ImagePropertiesForm.Result) {
        guard Self.fitsInMemory(width: result.width, height: result.height) else { return }
        let original = document.bitmap.grid
        var grid = original
        if result.width != grid.width || result.height != grid.height {
            grid = grid.withCanvasSize(width: result.width, height: result.height, background: state.secondary.packed)
        }
        if result.blackAndWhite {
            grid = grid.blackAndWhite()
        }
        guard grid != original else { return }
        document.replaceBitmap(Bitmap(grid: grid), actionName: localized("Image Properties"))
    }

    /// Pictures are kept as 32-bit pixels; past 400 million of them (1.6 GB) Paint would run out
    /// of memory, so say so instead of trying.
    static let maxPixelCount = 400_000_000

    static func fitsInMemory(width: Int, height: Int) -> Bool {
        guard width.multipliedReportingOverflow(by: height).partialValue > maxPixelCount || width.multipliedReportingOverflow(by: height).overflow else { return true }
        let alert = NSAlert()
        alert.messageText = localized("There is not enough memory to make a picture that large.")
        alert.informativeText = localized(format: "%ld × %ld pixels is more than this app can hold.", width, height)
        alert.runModal()
        return false
    }

    /// Applies `transforms` in order as one undo step. Uncovered areas are filled with color 2.
    func applyTransforms(_ transforms: [CanvasTransform], actionName: String) {
        commitText()
        guard !transforms.isEmpty else { return }
        let start = selection?.mask.rect ?? document.bitmap.bounds
        let size = transforms.reduce((start.width, start.height)) { $1.resultSize(width: $0.0, height: $0.1) }
        guard Self.fitsInMemory(width: size.0, height: size.1) else { return }
        // Rotate, Flip and Invert Color act on an active shape; anything else draws it first.
        if activeShape != nil {
            let turnsShape = transforms.allSatisfy {
                switch $0 {
                case .rotate, .flipHorizontal, .flipVertical, .invertColors: true
                default: false
                }
            }
            guard turnsShape else {
                commitActiveShape()
                return applyTransforms(transforms, actionName: actionName)
            }
            for transform in transforms {
                if transform == .invertColors { activeShape?.invertedColors.toggle() } else { activeShape?.apply(transform) }
            }
            redrawActiveShape()
            return
        }
        if let selection {
            var changed = PixelRect.zero
            for transform in transforms {
                changed = changed.union(selection.apply(transform, background: state.secondary))
            }
            selectionActionName = actionName
            bitmapDidChange(changed)
            needsDisplay = true
        } else {
            var grid = document.bitmap.grid
            for transform in transforms {
                grid = grid.applying(transform, background: state.secondary.packed)
            }
            document.replaceBitmap(Bitmap(grid: grid), actionName: actionName)
        }
    }
}

/// The fields of the Resize and Skew dialog, shown as an alert sheet.
final class ResizeSkewForm: NSObject, NSTextFieldDelegate {
    struct Result: Equatable {
        var width: Int
        var height: Int
        var skewHorizontal: Int
        var skewVertical: Int

        /// Resize first, then skew horizontally, then vertically: the order of
        /// `CPBView::OnImageStretchSkew`. Steps that change nothing are left out.
        func transforms(from originalWidth: Int, _ originalHeight: Int) -> [CanvasTransform] {
            var steps: [CanvasTransform] = []
            if width != originalWidth || height != originalHeight { steps.append(.resize(width: width, height: height)) }
            if skewHorizontal != 0 { steps.append(.skewHorizontal(degrees: skewHorizontal)) }
            if skewVertical != 0 { steps.append(.skewVertical(degrees: skewVertical)) }
            return steps
        }
    }

    /// Paint's limits: 1–500% by percentage, 1–99999 pixels by size (five-digit fields).
    static let maxPercent = 500
    static let maxPixels = 99_999

    let originalWidth: Int
    let originalHeight: Int
    let unitControl = NSSegmentedControl(labels: [localized("Percentage"), localized("Pixels")], trackingMode: .selectOne, target: nil, action: nil)
    let horizontalField = NSTextField(string: "100")
    let verticalField = NSTextField(string: "100")
    let keepRatioCheckbox = NSButton(checkboxWithTitle: localized("Maintain aspect ratio"), target: nil, action: nil)
    let skewHorizontalField = NSTextField(string: "0")
    let skewVerticalField = NSTextField(string: "0")
    private(set) var view = NSView()

    init(width: Int, height: Int) {
        originalWidth = width
        originalHeight = height
        super.init()
        unitControl.selectedSegment = 0
        unitControl.target = self
        unitControl.action = #selector(unitChanged)
        keepRatioCheckbox.state = .on
        for field in [horizontalField, verticalField, skewHorizontalField, skewVerticalField] {
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }

        let grid = NSGridView(views: [
            [label(localized("Resize"), bold: true), unitControl],
            [label(localized("Horizontal:")), horizontalField],
            [label(localized("Vertical:")), verticalField],
            [NSGridCell.emptyContentView, keepRatioCheckbox],
            [label(localized("Skew (degrees)"), bold: true), NSGridCell.emptyContentView],
            [label(localized("Horizontal:")), skewHorizontalField],
            [label(localized("Vertical:")), skewVerticalField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 4).topPadding = 8
        grid.frame.size = grid.fittingSize
        view = grid
    }

    var isPercentage: Bool { unitControl.selectedSegment == 0 }

    /// The dialog's values, clamped to what Paint accepts: skew within ±89°, size within
    /// 1–500 % of the original (the 500 % cap is this app's choice).
    var result: Result {
        func value(_ field: NSTextField, default fallback: Int) -> Int { Int(field.stringValue) ?? fallback }
        let width: Int, height: Int
        if isPercentage {
            width = scaled(originalWidth, percent: value(horizontalField, default: 100))
            height = scaled(originalHeight, percent: value(verticalField, default: 100))
        } else {
            width = min(max(value(horizontalField, default: originalWidth), 1), Self.maxPixels)
            height = min(max(value(verticalField, default: originalHeight), 1), Self.maxPixels)
        }
        let maxSkew = Skew.maxDegrees
        return Result(
            width: width,
            height: height,
            skewHorizontal: min(max(value(skewHorizontalField, default: 0), -maxSkew), maxSkew),
            skewVertical: min(max(value(skewVerticalField, default: 0), -maxSkew), maxSkew)
        )
    }

    static func run(width: Int, height: Int, on window: NSWindow, completion: @escaping (Result) -> Void) {
        let form = ResizeSkewForm(width: width, height: height)
        let alert = NSAlert()
        alert.messageText = localized("Resize and Skew")
        alert.accessoryView = form.view
        alert.addButton(withTitle: localized("OK"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(form.result) }
        }
    }

    // MARK: - Linked fields

    func controlTextDidChange(_ notification: Notification) {
        guard keepRatioCheckbox.state == .on, let field = notification.object as? NSTextField,
              let value = Int(field.stringValue) else { return }
        if field === horizontalField {
            verticalField.stringValue = String(isPercentage ? value : rounded(value * originalHeight, by: originalWidth))
        } else if field === verticalField {
            horizontalField.stringValue = String(isPercentage ? value : rounded(value * originalWidth, by: originalHeight))
        }
    }

    /// Converts the size fields when switching between percentage and pixels.
    @objc func unitChanged() {
        let horizontal = Int(horizontalField.stringValue) ?? 0
        let vertical = Int(verticalField.stringValue) ?? 0
        if isPercentage {
            horizontalField.stringValue = String(rounded(horizontal * 100, by: originalWidth))
            verticalField.stringValue = String(rounded(vertical * 100, by: originalHeight))
        } else {
            horizontalField.stringValue = String(scaled(originalWidth, percent: horizontal))
            verticalField.stringValue = String(scaled(originalHeight, percent: vertical))
        }
    }

    private func scaled(_ size: Int, percent: Int) -> Int {
        max(1, rounded(size * min(max(percent, 1), Self.maxPercent), by: 100))
    }

    private func rounded(_ numerator: Int, by denominator: Int) -> Int {
        (numerator + denominator / 2) / denominator
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return label
    }
}
