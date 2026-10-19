import AppKit
import Testing
import PaintCore
import UniformTypeIdentifiers
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)

private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

private func pngData(width: Int, height: Int, color: RGBA) throws -> Data {
    let image = try #require(Bitmap(width: width, height: height, fill: color).makeImage())
    return try ImageCodec.encode(image, as: .png)
}

@MainActor
@Suite(.serialized) struct AccessibilityTests {
    @Test func everyRibbonControlHasAName() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        controller.state.tool = .text // shows the Text tab too
        for tab in 0..<3 {
            ribbon.select(tab)
            let views = descendants(of: ribbon)
            let buttons = views.compactMap { $0 as? RibbonButton }
            #expect(!buttons.isEmpty)
            for button in buttons {
                #expect(button.accessibilityLabel()?.isEmpty == false)
            }
            for box in views.compactMap({ $0 as? NSComboBox }) {
                #expect(box.accessibilityLabel()?.isEmpty == false)
            }
        }
        ribbon.select(0)
        let toolNames = Set(controller.controls.tools.values.compactMap { $0.accessibilityLabel() })
        #expect(toolNames == Set([Tool.pencil, .fill, .text, .eraser, .picker, .magnifier].map(\.title)))

        let swatches = controller.controls.palettes[0].swatches
        #expect(swatches.count == 30)
        #expect(swatches.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
        #expect(Set(swatches.prefix(20).compactMap { $0.accessibilityLabel() }).count == 20, "every color has its own name")
        #expect(swatches.suffix(10).allSatisfy { !$0.isAccessibilityEnabled() }, "custom slots start empty")
    }

    @Test func paletteSetsTheActiveColorSlot() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let swatches = controller.controls.palettes[0].swatches
        let red = try #require(swatches.first { $0.accessibilityLabel() == localized("Red") })
        let green = try #require(swatches.first { $0.accessibilityLabel() == localized("Green") })

        #expect(red.accessibilityPerformPress())
        #expect(controller.state.primary == RGBA(237, 28, 36))
        controller.controls.color2[0].perform()
        #expect(controller.state.activeSlot == .secondary)
        #expect(green.accessibilityPerformPress())
        #expect(controller.state.secondary == RGBA(34, 177, 76), "now the palette sets Color 2")
        let other = try #require(red.accessibilityCustomActions()?.first)
        #expect(other.handler?() == true)
        #expect(controller.state.primary == RGBA(237, 28, 36), "the other slot (Shift+click)")
        #expect(ClassicPalette.name(of: RGBA(1, 2, 3)) == "Red 1, Green 2, Blue 3")
    }

    @Test func editColorsFillsTheCustomRow() {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        for value in 0..<12 { controller.applyEditedColor(RGBA(UInt8(value), 0, 0)) }
        controller.applyEditedColor(RGBA(5, 0, 0))
        let custom = controller.controls.palettes[0].swatches.suffix(10).map(\.color)
        #expect(custom.first == RGBA(2, 0, 0), "past 10 the oldest drop off")
        #expect(custom.last == RGBA(5, 0, 0), "a repeated color moves to the end")
        #expect(controller.state.primary == RGBA(5, 0, 0))
    }

    @Test func canvasDescribesItsSizeAndTool() {
        let state = EditorState()
        let document = CanvasDocument()
        let canvas = CanvasView(document: document, state: state)
        #expect(canvas.isAccessibilityElement())
        #expect(canvas.accessibilityRole() == .image)
        #expect(canvas.accessibilityLabel() == "Canvas, 800 × 600 px")
        state.tool = .fill
        #expect(canvas.accessibilityHelp() == Tool.fill.title)
        withExtendedLifetime(document) {}
    }
}

@MainActor
@Suite(.serialized) struct ImportTests {
    @Test func continuityCameraImageArrivesLikeAPaste() throws {
        let document = CanvasDocument()
        let canvas = CanvasView(document: document, state: EditorState())
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas

        #expect(canvas.validRequestor(forSendType: nil, returnType: .png) as? CanvasView === canvas)
        #expect(canvas.validRequestor(forSendType: nil, returnType: .string) as? CanvasView == nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SketchpadTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(!canvas.readSelection(from: pasteboard), "nothing to insert")
        pasteboard.setData(try pngData(width: 3, height: 2, color: blue), forType: .png)
        #expect(canvas.readSelection(from: pasteboard))
        #expect(canvas.selection?.mask.rect.width == 3 && canvas.selection?.mask.rect.height == 2)
        #expect(document.bitmap[PixelPoint(x: 0, y: 0)] == blue)
    }

    @Test func scannedFileOpensAsANewUnsavedPicture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).png")
        try pngData(width: 5, height: 4, color: blue).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try DeviceImportWindowController.makeDocument(fromImageAt: url)
        #expect(document.bitmap.width == 5 && document.bitmap.height == 4)
        #expect(document.bitmap[PixelPoint(x: 4, y: 3)] == blue)
        #expect(document.fileURL == nil)
        #expect(document.isDocumentEdited, "closing it asks to save")
        #expect(document.fileType != nil)
    }
}
