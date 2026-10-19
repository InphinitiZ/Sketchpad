import AppKit
import PaintCore
import UniformTypeIdentifiers

/// One open picture. The Objective-C name matches `NSDocumentClass` in Info.plist.
@objc(CanvasDocument)
final class CanvasDocument: NSDocument {
    static let newCanvasSize = (width: 800, height: 600)

    private(set) var bitmap = Bitmap(width: newCanvasSize.width, height: newCanvasSize.height)

    /// Called when pixels change outside an interactive stroke (undo, redo, revert).
    /// `nil` means the whole canvas, possibly with a new size.
    var onBitmapChange: ((PixelRect?) -> Void)?

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
        guard let image = ImageCodec.decode(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        bitmap = Bitmap(image: image)
        onBitmapChange?(nil)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let image = bitmap.makeImage(), let type = UTType(typeName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try ImageCodec.encode(image, as: type)
    }

    /// Records a finished edit. `before` holds the edited area as it was beforehand.
    func registerEdit(_ before: RegionSnapshot, actionName: String) {
        guard !before.rect.isEmpty else { return }
        registerSwap(before, actionName: actionName)
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
