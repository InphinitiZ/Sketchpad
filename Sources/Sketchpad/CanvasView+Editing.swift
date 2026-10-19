import AppKit
import PaintCore
import UniformTypeIdentifiers

/// Edit menu commands. The canvas is first responder while no text box is open, so these
/// receive the standard Cut, Copy, Paste, Delete, Select All, Undo and Redo actions.
extension CanvasView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        let rect = selection.mask.rect
        let pixels = selection.selectedPixels(outside: state.secondary)
        guard let image = Bitmap.makeImage(pixels: pixels, width: rect.width, height: rect.height) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PNG for modern apps, TIFF for everything else on macOS.
        for (type, uti) in [(NSPasteboard.PasteboardType.png, UTType.png), (.tiff, .tiff)] {
            if let data = try? ImageCodec.encode(image, as: uti) {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        selectionActionName = "Cut"
        delete(sender)
    }

    @objc func delete(_ sender: Any?) {
        guard let selection else { return }
        bitmapDidChange(selection.erase(background: state.secondary))
        if selectionActionName == "Move Selection" { selectionActionName = "Delete" }
        commitSelection()
    }

    /// Pastes at the top-left of the visible canvas, growing the canvas if the image is larger,
    /// and leaves the pasted pixels selected so they can be moved (Paint's behavior).
    @objc func paste(_ sender: Any?) {
        guard let image = Self.pasteboardImage() else { return }
        finishInteractions()
        state.tool = .select

        let source = Bitmap(image: image, background: state.secondary)
        var bitmap = document.bitmap
        var origin = PixelPoint(x: max(0, Int(visibleRect.minX)), y: max(0, Int(visibleRect.minY)))
        if source.width > bitmap.width || source.height > bitmap.height {
            let larger = Bitmap(
                width: max(bitmap.width, source.width),
                height: max(bitmap.height, source.height),
                fill: state.secondary
            )
            larger.stamp(bitmap.copyPixels(), mask: SelectionMask(rect: bitmap.bounds), skipping: nil)
            document.replaceBitmap(larger, actionName: "Paste")
            bitmap = larger
            origin = PixelPoint(x: 0, y: 0)
        }

        selection = SelectionSession(
            bitmap: bitmap,
            pasting: source.copyPixels(),
            width: source.width,
            height: source.height,
            at: origin,
            transparent: state.selectionTransparentColor
        )
        selectionActionName = "Paste"
        bitmapDidChange(nil)
    }

    @objc override func selectAll(_ sender: Any?) {
        finishInteractions()
        state.tool = .select
        select(SelectionMask(rect: document.bitmap.bounds))
    }

    /// Shrinks the canvas to the selection (Paint's Crop, Ctrl+Shift+X).
    @objc func crop(_ sender: Any?) {
        guard let selection else { return }
        let rect = selection.mask.rect
        let pixels = selection.selectedPixels(outside: state.secondary)
        commitSelection()
        document.replaceBitmap(Bitmap(width: rect.width, height: rect.height, pixels: pixels), actionName: "Crop")
    }

    /// Undo first commits a moved selection, then undoes it: both land in the same undo group,
    /// so the selection jumps back to where it was lifted from.
    @objc func undo(_ sender: Any?) {
        finishPendingShape()
        commitSelection()
        document.undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        finishPendingShape()
        commitSelection()
        document.undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let undoManager = document.undoManager
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(crop(_:)):
            return selection != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
        case #selector(undo(_:)):
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true || selection?.dirty.isEmpty == false
        case #selector(redo(_:)):
            menuItem.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        default:
            return true
        }
    }

    /// The first image on the general pasteboard, at its full pixel size.
    private static func pasteboardImage() -> CGImage? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = ImageCodec.decode(data) {
                return image
            }
        }
        return nil
    }
}
