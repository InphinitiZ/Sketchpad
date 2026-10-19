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
        selectionActionName = localized("Cut")
        delete(sender)
    }

    @objc func delete(_ sender: Any?) {
        if activeShape != nil {
            discardActiveShape()
            return
        }
        guard let selection else { return }
        bitmapDidChange(selection.erase(background: state.secondary))
        if selectionActionName == localized("Move Selection") { selectionActionName = localized("Delete") }
        commitSelection()
    }

    /// The image types the canvas reads from the pasteboard, best first.
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]

    @objc func paste(_ sender: Any?) {
        paste(from: .general)
    }

    /// Pastes at the top-left of the visible canvas, growing the canvas if the image is larger,
    /// and leaves the pasted pixels selected so they can be moved (Paint's behavior).
    /// Returns false if `pasteboard` holds no image.
    @discardableResult
    func paste(from pasteboard: NSPasteboard) -> Bool {
        guard let image = Self.image(on: pasteboard) else { return false }
        pasteImage(image)
        return true
    }

    func pasteImage(_ image: CGImage) {
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
            document.replaceBitmap(larger, actionName: localized("Paste"))
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
        selectionActionName = localized("Paste")
        bitmapDidChange(nil)
    }

    /// Paint's Paste From: pastes an image file as a floating selection.
    @objc func pasteFrom(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
                  let image = ImageCodec.decode(data) else { return }
            self?.pasteImage(image)
        }
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
        document.replaceBitmap(Bitmap(width: rect.width, height: rect.height, pixels: pixels), actionName: localized("Crop"))
    }

    /// Undo first commits a moved selection, then undoes it: both land in the same undo group,
    /// so the selection jumps back to where it was lifted from.
    @objc func undo(_ sender: Any?) {
        finishPendingShape()
        commitActiveShape()
        commitSelection()
        document.undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        finishPendingShape()
        commitActiveShape()
        commitSelection()
        document.undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let undoManager = document.undoManager
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(crop(_:)):
            return selection != nil
        case #selector(delete(_:)):
            return selection != nil || activeShape != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.availableType(from: Self.imageTypes) != nil
        case #selector(undo(_:)):
            menuItem.title = undoManager?.undoMenuItemTitle ?? localized("Undo")
            return undoManager?.canUndo == true || selection?.dirty.isEmpty == false
        case #selector(redo(_:)):
            menuItem.title = undoManager?.redoMenuItemTitle ?? localized("Redo")
            return undoManager?.canRedo == true
        default:
            return true
        }
    }

    /// The first image on `pasteboard`, at its full pixel size.
    private static func image(on pasteboard: NSPasteboard) -> CGImage? {
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let image = ImageCodec.decode(data) {
                return image
            }
        }
        return nil
    }
}

/// Continuity Camera (File > Import from iPhone or iPad) delivers its photo or scan through the
/// Services mechanism; it arrives like a paste.
extension CanvasView: NSServicesMenuRequestor {
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, Self.imageTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        paste(from: pasteboard)
    }
}
