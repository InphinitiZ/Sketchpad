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
    @Test func everySidebarControlHasAName() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let views = descendants(of: try #require(controller.window?.contentView))

        let popups = views.compactMap { $0 as? NSPopUpButton }
        #expect(popups.count >= 7)
        for popup in popups {
            #expect(popup.accessibilityLabel()?.isEmpty == false, "\(popup.titleOfSelectedItem ?? "?")")
        }
        let buttonNames = Set(views.compactMap { ($0 as? NSButton)?.accessibilityLabel() })
        #expect(Set(Tool.allCases.map(\.title)).isSubset(of: buttonNames), "image-only tool buttons are named")
        for control in views.compactMap({ $0 as? NSSegmentedControl }) {
            for index in 0..<control.segmentCount {
                let name = control.label(forSegment: index) ?? control.image(forSegment: index)?.accessibilityDescription
                #expect(name?.isEmpty == false)
            }
        }

        let swatches = views.compactMap { $0 as? ColorSwatch }
        #expect(swatches.count == 22)
        #expect(swatches.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
        #expect(Set(swatches.compactMap { $0.accessibilityLabel() }).count == 22, "every swatch has its own name")
    }

    @Test func paletteSwatchesSetBothColorsWithoutAMouse() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let swatches = descendants(of: try #require(controller.window?.contentView)).compactMap { $0 as? ColorSwatch }
        let red = try #require(swatches.first { $0.accessibilityLabel() == localized("Red") })
        let color1 = try #require(swatches.first { $0.title == localized("Color 1") })
        let color2 = try #require(swatches.first { $0.title == localized("Color 2") })

        #expect(red.accessibilityPerformPress())
        #expect(color1.accessibilityValue() as? String == localized("Red"))
        let setAsColor2 = try #require(red.accessibilityCustomActions()?.first)
        #expect(setAsColor2.name == localized("Set as Color 2"))
        #expect(setAsColor2.handler?() == true)
        #expect(color2.accessibilityValue() as? String == localized("Red"))
        #expect(ClassicPalette.name(of: RGBA(1, 2, 3)) == "Red 1, Green 2, Blue 3")
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
