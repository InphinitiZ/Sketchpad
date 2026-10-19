import AppKit
import UniformTypeIdentifiers

/// Paint's Save as ▸ PNG, JPEG, BMP, GIF and Other formats: the save panel opens with that
/// format chosen, and the document keeps its own format if the panel is cancelled.
extension CanvasDocument {
    @objc func saveAsPNG(_ sender: Any?) { saveAs(.png) }
    @objc func saveAsJPEG(_ sender: Any?) { saveAs(.jpeg) }
    @objc func saveAsBMP(_ sender: Any?) { saveAs(.bmp) }
    @objc func saveAsGIF(_ sender: Any?) { saveAs(.gif) }

    private func saveAs(_ type: UTType) {
        fileTypeBeforeSaveAs = fileType
        fileType = type.identifier
        runModalSavePanel(for: .saveAsOperation, delegate: self, didSave: #selector(saveAsFinished(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func saveAsFinished(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if !didSave, let previous = fileTypeBeforeSaveAs { fileType = previous }
        fileTypeBeforeSaveAs = nil
    }
}
