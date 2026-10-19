import AppKit
import Testing
import PaintCore
import UniformTypeIdentifiers
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)

private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
}

@MainActor
@Suite(.serialized) struct RecoveryAndMetadataTests {
    /// 3×2 photo whose EXIF says it must be turned a quarter clockwise.
    private func sidewaysPhoto() throws -> URL {
        let grid = PixelGrid(width: 3, height: 2, pixels: [blue.packed] + Array(repeating: RGBA.white.packed, count: 5))
        let url = temporaryURL("photo.jpg")
        try photoJPEG(grid, orientation: 6).write(to: url)
        return url
    }

    private func open(_ url: URL) throws -> CanvasDocument {
        let document = CanvasDocument()
        try document.read(from: url, ofType: UTType.jpeg.identifier)
        document.fileURL = url
        document.fileType = UTType.jpeg.identifier
        return document
    }

    private func save(_ document: CanvasDocument, to url: URL, as type: UTType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: type.identifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func make(of url: URL) -> String? {
        (ImageCodec.metadata(of: url)?.metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String
    }

    @Test func jpegPhotosOpenUpright() throws {
        let document = try open(sidewaysPhoto())
        #expect(document.bitmap.width == 2 && document.bitmap.height == 3, "turned a quarter")
        // The top-left blue pixel ends up top-right after a clockwise quarter turn.
        let corner = document.bitmap[PixelPoint(x: 1, y: 0)]
        #expect(Int(corner.b) > 150 && Int(corner.r) < 120, "blue (JPEG-approximate): \(corner)")
    }

    @Test func savingInTheSameFormatKeepsTheMetadata() async throws {
        let document = try open(sidewaysPhoto())
        let jpeg = temporaryURL("copy.jpg")
        try await save(document, to: jpeg, as: .jpeg)
        #expect(make(of: jpeg) == "Sketchpad Camera")
        #expect((ImageCodec.metadata(of: jpeg)?.metadata[kCGImagePropertyOrientation] as? Int) ?? 1 == 1)

        let png = temporaryURL("copy.png")
        try await save(document, to: png, as: .png)
        #expect(make(of: png) == nil, "another format leaves it behind, as in Paint")
        let again = temporaryURL("again.jpg")
        try await save(document, to: again, as: .jpeg)
        #expect(make(of: again) == nil, "the picture now comes from the PNG")
    }

    @Test func autosavesLeaveWorkInProgressAlone() throws {
        let document = CanvasDocument()
        var placed = 0
        document.willWrite = { placed += 1 }
        let url = temporaryURL("autosave.png")
        try document.write(to: url, ofType: UTType.png.identifier, for: .autosaveElsewhereOperation, originalContentsURL: nil)
        #expect(placed == 0, "an open text box or selection stays open")
        try document.write(to: url, ofType: UTType.png.identifier, for: .saveToOperation, originalContentsURL: nil)
        #expect(placed == 1)
        #expect(document.autosavingFileType == UTType.png.identifier, "autosaves are lossless")
    }

    @Test func oldAutosavesAreDropped() throws {
        let autosave = temporaryURL("autosave.png")
        try Data().write(to: autosave)
        let saved = temporaryURL("saved.png")
        #expect(DocumentController.recovery(for: saved, autosave: autosave) == .recover)
        let later = Date().addingTimeInterval(2 * 60 * 60 + 60)
        #expect(DocumentController.recovery(for: saved, autosave: autosave, now: later) == .openSaved(saved), "Paint's two-hour limit")
        #expect(DocumentController.recovery(for: nil, autosave: autosave, now: later) == .discard)
    }

    @Test func aRecoveredPictureSaysSoUntilSaved() async throws {
        let original = try sidewaysPhoto()
        // What the autosave held: the picture with a change.
        let edited = try open(original)
        edited.bitmap.fill(SelectionMask(rect: PixelRect(x: 0, y: 2, width: 2, height: 1)), with: blue)
        let autosave = temporaryURL("autosave.png")
        try edited.data(ofType: UTType.png.identifier).write(to: autosave)

        let recovered = try CanvasDocument(for: original, withContentsOf: autosave, ofType: UTType.jpeg.identifier)
        recovered.markRecovered(original: original)
        #expect(recovered.bitmap[PixelPoint(x: 0, y: 2)] == blue, "the autosaved changes are back")
        #expect(recovered.isDocumentEdited)
        #expect(recovered.displayName.hasSuffix(localized(format: "%@ (Recovered)", "").trimmingCharacters(in: .whitespaces)))
        #expect(recovered.carriesMetadata(as: .jpeg), "the photo's metadata comes from the saved file")

        try await save(recovered, to: temporaryURL("saved.jpg"), as: .jpeg)
        #expect(!recovered.isRecovered)
    }
}
