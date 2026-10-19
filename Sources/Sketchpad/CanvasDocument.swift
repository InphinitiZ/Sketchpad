import AppKit
import PaintCore
import UniformTypeIdentifiers

/// One open picture. The Objective-C name matches `NSDocumentClass` in Info.plist.
@objc(CanvasDocument)
final class CanvasDocument: NSDocument {
    /// The size Image Properties' Default button restores.
    static let defaultCanvasSize = (width: 800, height: 600)

    /// New pictures take the size of the last one (Paint's remembered `BMPWidth`/`BMPHeight`).
    static var newCanvasSize: (width: Int, height: Int) { Preferences.newPictureSize }

    private(set) var bitmap = Bitmap(width: newCanvasSize.width, height: newCanvasSize.height)
    /// Read from the file and written back on save; Image Properties shows it.
    var dotsPerInch = ImageCodec.defaultDotsPerInch

    /// Called when pixels change outside an interactive stroke (undo, redo, revert).
    /// `nil` means the whole canvas, possibly with a new size.
    var onBitmapChange: ((PixelRect?) -> Void)?

    /// Called before the picture is written out, so an open text box or selection can be committed.
    var willWrite: (() -> Void)?

    /// The format to go back to if a Save As started from a format choice is cancelled.
    var fileTypeBeforeSaveAs: String?
    /// The desktop layout waiting for a save to finish (Set as Desktop Background).
    var pendingDesktopLayout: DesktopLayout?
    /// The color depth for BMP files, chosen in the save panel (Paint's four bitmap types).
    var bitmapDepth = BitmapDepth.trueColor

    /// The format of the file the picture came from, and that file's metadata (camera, date,
    /// place …). Like Paint's `SaveDIBToFile`, saving in the same format carries it over.
    var sourceTypeIdentifier: String?
    var sourceMetadata: [CFString: Any] = [:]

    /// Reopened from its autosaved copy after a crash; the title says so until it is saved.
    var isRecovered = false
    /// Set while an autosave writes, which must not place a selection or text box.
    private var isAutosaving = false

    override init() {
        super.init()
        // Paint keeps 50 undo steps (set in CPBView::OnInitialUpdate).
        undoManager?.levelsOfUndo = 50
    }

    // Saving in place would recompress JPEGs on every autosave. Instead, changes are autosaved
    // elsewhere (as PNG, losslessly) for crash recovery; see `DocumentController`.
    override class var autosavesInPlace: Bool { false }

    override var autosavingFileType: String? { UTType.png.identifier }

    /// Paint's "%1 (Recovered)".
    override var displayName: String! {
        get { isRecovered ? localized(format: "%@ (Recovered)", super.displayName) : super.displayName }
        set { super.displayName = newValue }
    }

    override func makeWindowControllers() {
        addWindowController(CanvasWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = ImageCodec.decodeWithResolution(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bitmap = Bitmap(image: decoded.image)
        if decoded.opensUpright {
            bitmap = Bitmap(grid: bitmap.grid.upright(fromEXIFOrientation: decoded.orientation))
        }
        self.bitmap = bitmap
        dotsPerInch = decoded.dotsPerInch
        sourceTypeIdentifier = decoded.typeIdentifier
        sourceMetadata = decoded.metadata
        onBitmapChange?(nil)
    }

    /// Whether a save as `type` carries the source file's metadata: only in the same format.
    func carriesMetadata(as type: UTType) -> Bool {
        guard !sourceMetadata.isEmpty, let source = sourceTypeIdentifier.flatMap(UTType.init) else { return false }
        return source == type
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        isAutosaving = saveOperation == .autosaveElsewhereOperation || saveOperation == .autosaveInPlaceOperation
        defer { isAutosaving = false }
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
    }

    override func data(ofType typeName: String) throws -> Data {
        // An autosave takes the picture as it shows; only a real save places what is in progress.
        if !isAutosaving { willWrite?() }
        guard let image = bitmap.makeImage(), let type = UTType(typeName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if type.conforms(to: .bmp) {
            return ImageCodec.encodeBMP(bitmap.grid, depth: bitmapDepth, dotsPerInch: dotsPerInch)
        }
        let metadata = carriesMetadata(as: type) ? ImageCodec.carriedMetadata(sourceMetadata, width: bitmap.width, height: bitmap.height) : nil
        return try ImageCodec.encode(image, as: type, dotsPerInch: dotsPerInch, metadata: metadata)
    }

    /// After a save, the file just written is the source: a different format leaves the
    /// metadata behind, as it would for Paint, and a recovered picture is recovered no longer.
    private func didSave(as typeName: String, for saveOperation: NSDocument.SaveOperationType) {
        guard saveOperation == .saveOperation || saveOperation == .saveAsOperation else { return }
        if let type = UTType(typeName), !carriesMetadata(as: type) {
            sourceMetadata = [:]
            sourceTypeIdentifier = typeName
        }
        isRecovered = false
    }

    /// Whether `type` holds fewer colors than the picture has (Paint warns before saving).
    func savingLosesColors(as type: UTType) -> Bool {
        if type.conforms(to: .bmp) { return bitmap.grid.losesColors(at: bitmapDepth) }
        if type.conforms(to: .gif) { return bitmap.grid.losesColors(at: .twoHundredFiftySixColors) }
        return false
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let completionHandler: (Error?) -> Void = { [weak self] error in
            if error == nil { self?.didSave(as: typeName, for: saveOperation) }
            completionHandler(error)
        }
        guard saveOperation != .autosaveElsewhereOperation, saveOperation != .autosaveInPlaceOperation,
              let type = UTType(typeName), savingLosesColors(as: type) else {
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            return
        }
        let alert = NSAlert()
        alert.messageText = localized("Saving in this format may reduce the picture's color quality.")
        alert.informativeText = localized("Do you want to continue?")
        alert.addButton(withTitle: localized("Continue"))
        alert.addButton(withTitle: localized("Cancel"))
        let proceed = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            } else {
                completionHandler(CocoaError(.userCancelled))
            }
        }
        if let window = windowForSheet {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// Adds Paint's bitmap color depths beside the format menu of the save panel.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let depth = NSPopUpButton()
        depth.addItems(withTitles: [
            localized("Monochrome Bitmap"), localized("16 Color Bitmap"), localized("256 Color Bitmap"), localized("24-bit Bitmap"),
        ])
        depth.selectItem(at: BitmapDepth.allCases.firstIndex(of: bitmapDepth) ?? 3)
        depth.target = self
        depth.action = #selector(bitmapDepthChanged(_:))
        let label = NSTextField(labelWithString: localized("BMP colors:"))
        let row = NSStackView(views: [label, depth])
        var views: [NSView] = []
        if let existing = savePanel.accessoryView { views.append(existing) }
        views.append(row)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        stack.frame.size = stack.fittingSize
        savePanel.accessoryView = stack
        return true
    }

    @objc private func bitmapDepthChanged(_ sender: NSPopUpButton) {
        bitmapDepth = BitmapDepth.allCases[max(0, sender.indexOfSelectedItem)]
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        willWrite?()
        guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        // Paint prints a picture larger than the page across as many pages as it takes, both
        // ways (AppKit clips the width by default).
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        let view = PrintView(image: image, dotsPerInch: dotsPerInch)
        if let scale = PageSetupAccessory.fitScale(for: view.frame.size, info: info) {
            info.scalingFactor = scale
        }
        return NSPrintOperation(view: view, printInfo: info)
    }

    override func preparePageLayout(_ pageLayout: NSPageLayout) -> Bool {
        pageLayout.addAccessoryController(PageSetupAccessory())
        return true
    }

    /// Records a finished edit. `before` holds the edited area as it was beforehand.
    func registerEdit(_ before: RegionSnapshot, actionName: String) {
        guard !before.rect.isEmpty else { return }
        registerSwap(before, actionName: actionName)
    }

    /// Swaps in a different bitmap, for edits that change the canvas size (crop, paste into a
    /// larger area). Undo keeps the whole previous bitmap.
    func replaceBitmap(_ newBitmap: Bitmap, actionName: String) {
        let old = bitmap
        bitmap = newBitmap
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceBitmap(old, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        onBitmapChange?(nil)
    }

    /// Undo and redo are the same operation: swap the stored pixels with the current ones.
    private func registerSwap(_ snapshot: RegionSnapshot, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { document in
            let current = document.bitmap.snapshot(snapshot.rect)
            document.bitmap.restore(snapshot)
            document.registerSwap(current, actionName: actionName)
            document.onBitmapChange?(snapshot.rect)
        }
        undoManager?.setActionName(actionName)
    }
}
