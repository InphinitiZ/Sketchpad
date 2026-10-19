import AppKit
import PaintCore
import UniformTypeIdentifiers

/// File menu commands that hand the picture to the rest of the system.
extension CanvasDocument {
    /// Paint's Send in Email: a new message with the picture attached.
    @objc func sendInEmail(_ sender: Any?) {
        guard let url = try? exportedCopy(), let service = NSSharingService(named: .composeEmail) else {
            NSSound.beep()
            return
        }
        service.subject = displayName
        service.perform(withItems: [url])
    }

    /// Paint's Set as Desktop Background, in its three layouts.
    @objc func setDesktopBackgroundFill(_ sender: Any?) {
        setDesktopBackground(.fill)
    }

    @objc func setDesktopBackgroundTile(_ sender: Any?) {
        setDesktopBackground(.tile)
    }

    @objc func setDesktopBackgroundCenter(_ sender: Any?) {
        setDesktopBackground(.center)
    }

    enum DesktopLayout: Int {
        case fill, tile, center
    }

    /// Paint sets the saved file itself, so an unsaved or changed picture must be saved first.
    func setDesktopBackground(_ layout: DesktopLayout) {
        guard let url = fileURL, !isDocumentEdited else {
            let alert = NSAlert()
            alert.messageText = localized("You must save the picture before setting it as the desktop background.")
            alert.addButton(withTitle: localized("Save"))
            alert.addButton(withTitle: localized("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            pendingDesktopLayout = layout
            save(withDelegate: self, didSave: #selector(savedForDesktop(_:didSave:contextInfo:)), contextInfo: nil)
            return
        }
        applyDesktopBackground(layout, file: url)
    }

    @objc private func savedForDesktop(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        defer { pendingDesktopLayout = nil }
        guard didSave, let layout = pendingDesktopLayout, let url = fileURL else { return }
        applyDesktopBackground(layout, file: url)
    }

    private func applyDesktopBackground(_ layout: DesktopLayout, file: URL) {
        do {
            for screen in NSScreen.screens {
                var url = file
                var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
                switch layout {
                case .fill:
                    options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
                    options[.allowClipping] = true
                case .center:
                    options[.imageScaling] = NSImageScaling.scaleNone.rawValue
                    options[.allowClipping] = false
                    options[.fillColor] = NSColor.black
                case .tile:
                    // macOS has no tiled layout, so lay the tiles out in a screen-sized picture.
                    url = try tiledCopy(for: screen)
                    options[.imageScaling] = NSImageScaling.scaleNone.rawValue
                    options[.allowClipping] = true
                }
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            }
        } catch {
            presentError(error)
        }
    }

    /// The picture as a PNG in the app's support folder, kept so the desktop and mail can use it.
    func exportedCopy(named name: String? = nil) throws -> URL {
        willWrite?()
        guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let folder = try Self.exportFolder()
        let base = name ?? (displayName as NSString).deletingPathExtension
        let url = folder.appendingPathComponent(base).appendingPathExtension("png")
        try ImageCodec.encode(image, as: .png, dotsPerInch: dotsPerInch).write(to: url, options: .atomic)
        return url
    }

    private func tiledCopy(for screen: NSScreen) throws -> URL {
        willWrite?()
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let tiles = Bitmap(width: width, height: height)
        let source = bitmap.copyPixels()
        let tile = SelectionMask(rect: PixelRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        for y in stride(from: 0, to: height, by: bitmap.height) {
            for x in stride(from: 0, to: width, by: bitmap.width) {
                tiles.stamp(source, mask: tile.offsetBy(dx: x, dy: y), skipping: nil)
            }
        }
        guard let image = tiles.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let url = try Self.exportFolder().appendingPathComponent("Tiled Background \(Int(size.width))x\(Int(size.height))").appendingPathExtension("png")
        try ImageCodec.encode(image, as: .png).write(to: url, options: .atomic)
        return url
    }

    private static func exportFolder() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Sketchpad").appendingPathComponent("Shared Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
