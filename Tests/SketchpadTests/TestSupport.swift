import AppKit
import ImageIO
import PaintCore
@testable import Sketchpad

/// A document shown the way the app shows it (canvas in the workspace in a scroll view, in an
/// offscreen window), driven with synthesized events.
@MainActor
final class Stage {
    let document = CanvasDocument()
    let state = EditorState()
    let canvas: CanvasView
    let workspace: CanvasWorkspaceView
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    let window: NSWindow

    init() {
        canvas = CanvasView(document: document, state: state)
        workspace = CanvasWorkspaceView(canvasView: canvas)
        scrollView.documentView = workspace
        window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scrollView
        workspace.updateLayout()
    }

    var bitmap: Bitmap { document.bitmap }

    func send(_ type: NSEvent.EventType, at p: PixelPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        let location = canvas.convert(NSPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5), to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .rightMouseDown: canvas.rightMouseDown(with: event)
        case .rightMouseDragged: canvas.rightMouseDragged(with: event)
        case .rightMouseUp: canvas.rightMouseUp(with: event)
        case .mouseMoved: canvas.mouseMoved(with: event)
        default: canvas.mouseUp(with: event)
        }
        settle()
    }

    func drag(from a: PixelPoint, to b: PixelPoint, modifiers: NSEvent.ModifierFlags = []) {
        send(.leftMouseDown, at: a, modifiers: modifiers)
        send(.leftMouseDragged, at: b, modifiers: modifiers)
        send(.leftMouseUp, at: b, modifiers: modifiers)
    }

    func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        canvas.keyDown(with: event)
        settle()
    }

    /// Lets the run loop turn over so the undo manager closes its per-event group.
    func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    func undo() {
        canvas.undo(nil)
        settle()
    }
}

/// Runs `body` with settings of its own, empty at the start, so tests that read or change
/// them neither see nor disturb the ones running alongside.
func withFreshPreferences<T>(_ body: () throws -> T) rethrows -> T {
    let name = "dev.local.Sketchpad.test-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: name)!
    defer { store.removePersistentDomain(forName: name) }
    return try Preferences.$current.withValue(Preferences.Store(defaults: store), operation: body)
}

/// A JPEG of `grid` with camera metadata (make, date, place) and the given EXIF orientation.
func photoJPEG(_ grid: PixelGrid, orientation: Int) throws -> Data {
    guard let image = Bitmap(grid: grid).makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 1.0,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sketchpad Camera", kCGImagePropertyTIFFOrientation: orientation],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:19 08:30:00"],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}
