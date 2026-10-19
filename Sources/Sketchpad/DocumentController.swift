import AppKit
import PaintCore

/// Crash recovery. Paint registers with Windows' application recovery: when it crashes, it
/// writes the picture to a recovery file and Windows restarts it, reopening the picture as
/// "%1 (Recovered)", marked as changed (`PaintRecoveryCallback`). On the Mac the same comes
/// from autosaving: changes are written to the system's autosave folder every few seconds,
/// and after a crash the restored windows reopen those copies.
final class DocumentController: NSDocumentController {
    /// How soon changes are autosaved (this app's choice).
    static let autosaveDelay: TimeInterval = 15
    /// Paint ignores recovery data over two hours old (`RecoveryData::IsOld`).
    static let recoveryLifetime: TimeInterval = 2 * 60 * 60

    override init() {
        super.init()
        autosavingDelay = Self.autosaveDelay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        autosavingDelay = Self.autosaveDelay
    }

    enum Recovery: Equatable {
        /// Reopen the autosaved copy as a recovered picture.
        case recover
        /// The copy is too old: open the file as last saved.
        case openSaved(URL)
        /// The copy is too old and there is no saved file: nothing to reopen.
        case discard
    }

    /// What to do with an autosaved copy found at relaunch.
    static func recovery(for original: URL?, autosave: URL, now: Date = Date()) -> Recovery {
        let modified = (try? autosave.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
        guard now.timeIntervalSince(modified) > recoveryLifetime else { return .recover }
        return original.map(Recovery.openSaved) ?? .discard
    }

    override func reopenDocument(
        for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        guard urlOrNil != contentsURL else {
            super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL, display: displayDocument, completionHandler: completionHandler)
            return
        }
        switch Self.recovery(for: urlOrNil, autosave: contentsURL) {
        case .recover:
            super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL, display: displayDocument) { document, alreadyOpen, error in
                (document as? CanvasDocument)?.markRecovered(original: urlOrNil)
                completionHandler(document, alreadyOpen, error)
            }
        case let .openSaved(original):
            try? FileManager.default.removeItem(at: contentsURL)
            super.reopenDocument(for: original, withContentsOf: original, display: displayDocument, completionHandler: completionHandler)
        case .discard:
            try? FileManager.default.removeItem(at: contentsURL)
            completionHandler(nil, false, CocoaError(.userCancelled))
        }
    }
}

extension CanvasDocument {
    /// Marks a picture reopened from its autosaved copy. Its pixels came from the copy, but
    /// the photo's metadata still lives in the saved file, so it is read from there.
    func markRecovered(original: URL?) {
        isRecovered = true
        if let original, let source = ImageCodec.metadata(of: original) {
            sourceTypeIdentifier = source.typeIdentifier
            sourceMetadata = source.metadata
        }
        for controller in windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
    }
}
