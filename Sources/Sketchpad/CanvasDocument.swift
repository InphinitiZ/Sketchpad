import AppKit
import PaintCore
import UniformTypeIdentifiers

/// One open picture. The Objective-C name matches `NSDocumentClass` in Info.plist.
@objc(CanvasDocument)
final class CanvasDocument: NSDocument {
    static let newCanvasSize = (width: 800, height: 600)

    private(set) var bitmap = Bitmap(width: newCanvasSize.width, height: newCanvasSize.height)
    /// Read from the file and written back on save; Image Properties shows it.
    var dotsPerInch = ImageCodec.defaultDotsPerInch

    /// Called when pixels change outside an interactive stroke (undo, redo, revert).
    /// `nil` means the whole canvas, possibly with a new size.
    var onBitmapChange: ((PixelRect?) -> Void)?

    /// Called before the picture is written out, so an open text box or selection can be committed.
    var willWrite: (() -> Void)?

    override init() {
        super.init()
        // Paint keeps 50 undo steps (set in CPBView::OnInitialUpdate).
        undoManager?.levelsOfUndo = 50
    }

    // Saving in place would recompress JPEGs on every autosave.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(CanvasWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = ImageCodec.decodeWithResolution(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        bitmap = Bitmap(image: decoded.image)
        dotsPerInch = decoded.dotsPerInch
        onBitmapChange?(nil)
    }

    override func data(ofType typeName: String) throws -> Data {
        willWrite?()
        guard let image = bitmap.makeImage(), let type = UTType(typeName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try ImageCodec.encode(image, as: type, dotsPerInch: dotsPerInch)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        willWrite?()
        guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        return NSPrintOperation(view: PrintView(image: image, dotsPerInch: dotsPerInch), printInfo: info)
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
