import AppKit
import Testing
import PaintCore
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// A document and canvas in an offscreen window, driven with synthesized mouse events.
@MainActor
private final class Harness {
    let document = CanvasDocument()
    let state = EditorState()
    let canvas: CanvasView
    let window: NSWindow

    init() {
        canvas = CanvasView(document: document, state: state)
        window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas
    }

    var bitmap: Bitmap { document.bitmap }

    func drag(from a: PixelPoint, to b: PixelPoint) {
        send(.leftMouseDown, at: a)
        send(.leftMouseDragged, at: b)
        send(.leftMouseUp, at: b)
    }

    func click(at p: PixelPoint) {
        send(.leftMouseDown, at: p)
        send(.leftMouseUp, at: p)
    }

    func send(_ type: NSEvent.EventType, at p: PixelPoint, clickCount: Int = 1) {
        let location = canvas.convert(NSPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5), to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .mouseMoved: canvas.mouseMoved(with: event)
        default: canvas.mouseUp(with: event)
        }
        endEvent()
    }

    func pressEscape() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
        canvas.keyDown(with: event)
    }

    /// Lets the run loop turn over so the undo manager closes its per-event group.
    func endEvent() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}

@MainActor
@Suite(.serialized) struct CanvasInteractionTests {
    @Test func movingASelectionIsOneUndoStep() {
        let h = Harness()
        h.bitmap.fill(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 5, height: 5)), with: blue)
        h.state.tool = .select

        h.drag(from: point(10, 10), to: point(14, 14))
        #expect(h.canvas.selection?.mask.rect == PixelRect(x: 10, y: 10, width: 5, height: 5))

        h.drag(from: point(12, 12), to: point(42, 12))
        #expect(h.bitmap[point(12, 12)] == .white)
        #expect(h.bitmap[point(42, 12)] == blue)

        // Undo while the selection is still floating puts it back where it was lifted from.
        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.canvas.selection == nil)
        #expect(h.bitmap[point(12, 12)] == blue)
        #expect(h.bitmap[point(42, 12)] == .white)
        #expect(h.document.undoManager?.canUndo == false)
    }

    @Test func clickingOutsideDeselectsAndKeepsTheMove() {
        let h = Harness()
        h.bitmap.fill(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 5, height: 5)), with: blue)
        h.state.tool = .select
        h.drag(from: point(10, 10), to: point(14, 14))
        h.drag(from: point(12, 12), to: point(12, 52))
        h.click(at: point(200, 200))

        #expect(h.canvas.selection == nil)
        #expect(h.bitmap[point(12, 52)] == blue)
        #expect(h.document.undoManager?.undoActionName == localized("Move Selection"))
    }

    @Test func cropShrinksCanvasAndUndoRestoresIt() {
        let h = Harness()
        h.bitmap.fill(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 5, height: 5)), with: blue)
        h.state.tool = .select
        h.drag(from: point(10, 10), to: point(19, 14))
        h.canvas.crop(nil)
        h.endEvent()

        #expect(h.bitmap.width == 10 && h.bitmap.height == 5)
        #expect(h.bitmap[point(0, 0)] == blue)
        #expect(h.bitmap[point(9, 0)] == .white)

        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.bitmap.width == CanvasDocument.newCanvasSize.width)
    }

    @Test func copyThenPasteFloatsAtTopLeft() {
        let h = Harness()
        h.bitmap.fill(SelectionMask(rect: PixelRect(x: 30, y: 30, width: 4, height: 4)), with: blue)
        h.state.tool = .select
        h.drag(from: point(30, 30), to: point(33, 33))
        h.canvas.copy(nil)
        h.click(at: point(300, 300))

        h.canvas.paste(nil)
        h.endEvent()
        #expect(h.canvas.selection?.isFloating == true)
        #expect(h.bitmap[point(0, 0)] == blue)

        h.drag(from: point(1, 1), to: point(101, 1))
        #expect(h.bitmap[point(0, 0)] == .white)
        #expect(h.bitmap[point(100, 0)] == blue)
    }

    @Test func freeFormSelectionDeleteFillsWithColor2() {
        let h = Harness()
        h.bitmap.fill(SelectionMask(rect: h.bitmap.bounds), with: blue)
        h.state.tool = .freeFormSelect
        h.send(.leftMouseDown, at: point(10, 10))
        for p in [point(50, 10), point(50, 50), point(10, 50)] { h.send(.leftMouseDragged, at: p) }
        h.send(.leftMouseUp, at: point(10, 50))

        h.canvas.delete(nil)
        h.endEvent()
        #expect(h.bitmap[point(30, 30)] == .white)
        #expect(h.bitmap[point(60, 60)] == blue)
    }
}

@MainActor
@Suite struct TextBoxTests {
    @Test func renderedTextIsUprightInsideItsBox() throws {
        var style = TextStyle()
        style.points = 36
        let frame = NSRect(x: 20, y: 30, width: 300, height: 60)
        let box = TextBox(frame: frame, style: style, color: .black, background: .white)
        box.textView.insertText("Ty", replacementRange: NSRange(location: 0, length: 0))

        let bitmap = Bitmap(width: 400, height: 200)
        box.render(into: bitmap, opaque: false, background: .white)

        // Find the inked rows.
        var inkRows: [Int] = []
        for y in 0..<bitmap.height where (0..<bitmap.width).contains(where: { bitmap[point($0, y)] != .white }) {
            inkRows.append(y)
        }
        let top = try #require(inkRows.first), bottom = try #require(inkRows.last)
        #expect(top >= 30 && CGFloat(bottom) < box.textView.frame.maxY, "text stays inside its box")
        // Upright: the "T" crossbar is the first inked row, so the leftmost ink there is the
        // crossbar's left end, near the box's left edge.
        let crossbarLeft = try #require((0..<bitmap.width).first { bitmap[point($0, top)] != .white })
        #expect(crossbarLeft < 40)
    }

    @Test func opaqueBackgroundFillsTheBox() {
        var style = TextStyle()
        style.opaque = true
        let red = RGBA(237, 28, 36)
        let box = TextBox(frame: NSRect(x: 10, y: 10, width: 100, height: 30), style: style, color: .black, background: red)
        box.textView.string = "a"
        let bitmap = Bitmap(width: 200, height: 100)
        box.render(into: bitmap, opaque: true, background: red)
        #expect(bitmap[point(100, 35)] == red)
        #expect(bitmap[point(150, 35)] == .white)
    }
}

@MainActor
@Suite(.serialized) struct ImageCommandTests {
    @Test func rotatingThePictureSwapsItsSizeAndUndoRestoresIt() {
        let h = Harness()
        h.bitmap[point(0, 0)] = blue
        h.canvas.rotateRight(nil)
        h.endEvent()
        #expect(h.bitmap.width == 600 && h.bitmap.height == 800)
        #expect(h.bitmap[point(599, 0)] == blue, "top-left corner goes to top-right")

        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.bitmap.width == 800 && h.bitmap[point(0, 0)] == blue)
    }

    @Test func flippingActsOnTheSelectionOnly() {
        let h = Harness()
        h.bitmap[point(10, 10)] = blue
        h.bitmap[point(100, 100)] = blue
        h.state.tool = .select
        h.drag(from: point(10, 10), to: point(19, 19))
        h.canvas.flipHorizontal(nil)
        h.endEvent()

        #expect(h.bitmap[point(19, 10)] == blue)
        #expect(h.bitmap[point(10, 10)] == .white)
        #expect(h.bitmap[point(100, 100)] == blue, "outside the selection is untouched")
        #expect(h.bitmap.width == 800)

        h.click(at: point(300, 300))
        #expect(h.document.undoManager?.undoActionName == localized("Flip"))
    }

    @Test func resizeAndSkewIsOneUndoStep() {
        let h = Harness()
        h.canvas.applyTransforms([.resize(width: 400, height: 300), .skewHorizontal(degrees: 45)], actionName: "Resize and Skew")
        h.endEvent()
        #expect(h.bitmap.width == 700 && h.bitmap.height == 300)

        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.bitmap.width == 800 && h.bitmap.height == 600)
    }

    @Test func skewFillsUncoveredCornersWithColor2() {
        let h = Harness()
        h.state.secondary = blue
        h.canvas.applyTransforms([.skewHorizontal(degrees: 45)], actionName: "Skew")
        #expect(h.bitmap[point(0, 0)] == blue)
        #expect(h.bitmap[point(799, 0)] == .white)
    }
}

@MainActor
@Suite struct ResizeSkewFormTests {
    @Test func percentageWithLockedRatioMirrorsTheOtherField() {
        let form = ResizeSkewForm(width: 800, height: 600)
        #expect(form.view.frame.width > 200 && form.view.frame.height > 150, "the alert sizes its accessory view from this frame")
        form.horizontalField.stringValue = "50"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.horizontalField))
        #expect(form.verticalField.stringValue == "50")
        #expect(form.result == .init(width: 400, height: 300, skewHorizontal: 0, skewVertical: 0))
    }

    @Test func pixelsKeepTheAspectRatio() {
        let form = ResizeSkewForm(width: 800, height: 600)
        form.unitControl.selectedSegment = 1
        form.unitChanged()
        #expect(form.horizontalField.stringValue == "800")
        form.horizontalField.stringValue = "200"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.horizontalField))
        #expect(form.verticalField.stringValue == "150")
    }

    @Test func valuesAreClampedToPaintsLimits() {
        let form = ResizeSkewForm(width: 100, height: 100)
        form.horizontalField.stringValue = "9000"
        form.verticalField.stringValue = "0"
        form.skewHorizontalField.stringValue = "120"
        form.skewVerticalField.stringValue = "-120"
        #expect(form.result == .init(width: 500, height: 1, skewHorizontal: 89, skewVertical: -89))
    }

    @Test func unchangedStepsAreLeftOut() {
        let result = ResizeSkewForm.Result(width: 800, height: 600, skewHorizontal: 0, skewVertical: 10)
        #expect(result.transforms(from: 800, 600) == [.skewVertical(degrees: 10)])
    }
}

@MainActor
@Suite(.serialized) struct ShapeAndBrushToolTests {
    @Test func boxShapeIsDrawnWithOutlineAndFill() {
        let h = Harness()
        h.state.tool = .shape
        h.state.shapeKind = .diamond
        h.state.shapeFill = .solid
        h.state.secondary = blue
        h.drag(from: point(100, 100), to: point(200, 200))
        #expect(h.bitmap[point(150, 150)] == blue, "filled with color 2")
        #expect(h.bitmap[point(105, 105)] == .white, "diamond leaves the corners empty")
        #expect(h.canvas.activeShape != nil, "the shape stays editable")
        h.canvas.commitActiveShape()
        h.endEvent()
        #expect(h.document.undoManager?.undoActionName == ShapeKind.diamond.title)
    }

    @Test func curveTakesALineAndTwoBends() {
        let h = Harness()
        h.state.tool = .shape
        h.state.shapeKind = .curve
        h.drag(from: point(100, 300), to: point(300, 300))
        #expect(h.canvas.pendingShape != nil)
        #expect(h.bitmap[point(200, 300)] == .black, "starts as a straight line")

        h.drag(from: point(200, 300), to: point(200, 100))
        #expect(h.canvas.pendingShape != nil, "one bend so far")
        #expect(h.bitmap[point(200, 300)] == .white, "the middle has moved up")

        h.drag(from: point(200, 100), to: point(250, 120))
        #expect(h.canvas.pendingShape == nil)
        #expect(h.canvas.activeShape?.kind == .curve, "finished curves stay editable")
        h.canvas.commitActiveShape()
        h.endEvent()
        #expect(h.document.undoManager?.undoActionName == ShapeKind.curve.title)
        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.bitmap[point(100, 300)] == .white)
    }

    @Test func polygonClosesOnDoubleClick() {
        let h = Harness()
        h.state.tool = .shape
        h.state.shapeKind = .polygon
        h.state.shapeFill = .solid
        h.state.secondary = blue
        h.drag(from: point(100, 100), to: point(300, 100))
        h.click(at: point(300, 300))
        h.send(.leftMouseDown, at: point(100, 300), clickCount: 1)
        h.send(.leftMouseUp, at: point(100, 300), clickCount: 1)
        #expect(h.canvas.pendingShape != nil)
        h.send(.leftMouseDown, at: point(100, 300), clickCount: 2)
        h.send(.leftMouseUp, at: point(100, 300), clickCount: 2)

        #expect(h.canvas.pendingShape == nil)
        #expect(h.bitmap[point(200, 200)] == blue, "closed and filled")
        #expect(h.bitmap[point(100, 200)] == .black, "closing side drawn")
    }

    @Test func escapeDiscardsAPolygonInProgress() {
        let h = Harness()
        h.state.tool = .shape
        h.state.shapeKind = .polygon
        h.drag(from: point(100, 100), to: point(300, 100))
        h.send(.mouseMoved, at: point(300, 300))
        h.pressEscape()
        #expect(h.canvas.pendingShape == nil)
        #expect(h.bitmap[point(200, 100)] == .white)
        #expect(h.document.undoManager?.canUndo == false)
    }

    @Test func switchingToolsFinishesAPolygon() {
        let h = Harness()
        h.state.tool = .shape
        h.state.shapeKind = .polygon
        h.drag(from: point(100, 100), to: point(300, 100))
        h.click(at: point(300, 300))
        h.state.tool = .pencil
        #expect(h.canvas.pendingShape == nil)
        #expect(h.bitmap[point(200, 200)] != .white, "closed back to the first corner (an antialiased diagonal)")
    }

    @Test func calligraphyBrushPaintsWithColor1() {
        let h = Harness()
        h.state.tool = .brush
        h.state.brushKind = .calligraphy45
        h.state.size = 8
        h.state.primary = blue
        h.drag(from: point(100, 100), to: point(200, 100))
        #expect(h.bitmap[point(150, 100)] == blue)
        #expect(h.bitmap[point(150, 97)] == blue, "the nib is 8 pixels tall when dragged sideways")
        #expect(h.document.undoManager?.undoActionName == Tool.brush.title)
    }

    @Test func airbrushKeepsSprayingWhileHeld() {
        let h = Harness()
        h.state.tool = .brush
        h.state.brushKind = .airbrush
        h.state.primary = blue
        h.send(.leftMouseDown, at: point(200, 200))
        func dots() -> Int {
            (170...230).reduce(0) { sum, y in sum + (170...230).filter { h.bitmap[point($0, y)] == blue }.count }
        }
        let first = dots()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        #expect(dots() > first, "the timer adds bursts while the mouse is still")
        h.send(.leftMouseUp, at: point(200, 200))
        let final = dots()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        #expect(dots() == final, "and stops on mouse-up")
    }
}

@MainActor
@Suite(.serialized) struct PropertiesAndViewTests {
    @Test func propertiesConvertUnitsWithTheImageResolution() {
        withFreshPreferences {
            let form = ImagePropertiesForm(width: 960, height: 480, dotsPerInch: 96, lastSaved: nil, sizeOnDisk: nil)
            #expect(form.view.frame.width > 200)
            form.unitControl.selectedSegment = ImagePropertiesForm.Unit.inches.rawValue
            form.unitChanged()
            #expect(form.widthField.stringValue == "10.00")
            #expect(form.heightField.stringValue == "5.00")

            form.widthField.stringValue = "2.5"
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.widthField))
            form.unitControl.selectedSegment = ImagePropertiesForm.Unit.centimeters.rawValue
            form.unitChanged()
            #expect(form.widthField.stringValue == "6.35")
            #expect(form.result == .init(width: 240, height: 480, blackAndWhite: false))

            form.restoreDefaultSize()
            form.colorControl.selectedSegment = 0
            #expect(form.result == .init(width: 800, height: 600, blackAndWhite: true))
        }
    }

    @Test func growingTheCanvasFillsWithColor2AndUndoes() {
        let h = Harness()
        h.state.secondary = blue
        h.bitmap[point(0, 0)] = .black
        h.canvas.applyImageProperties(.init(width: 1000, height: 600, blackAndWhite: false))
        h.endEvent()
        #expect(h.bitmap.width == 1000)
        #expect(h.bitmap[point(0, 0)] == .black)
        #expect(h.bitmap[point(900, 10)] == blue)
        #expect(h.bitmap[point(700, 10)] == .white, "the old picture is not stretched")
        h.canvas.undo(nil)
        h.endEvent()
        #expect(h.bitmap.width == 800)
    }

    @Test func printingUsesTheResolution() throws {
        let document = CanvasDocument()
        document.dotsPerInch = 96
        let operation = try document.printOperation(withSettings: [:])
        #expect(operation.view?.frame.size == NSSize(width: 600, height: 450))
    }

    @Test func viewMenuToggles() {
        withFreshPreferences {
            let document = CanvasDocument()
            let controller = CanvasWindowController(document: document)
            defer { withExtendedLifetime(document) {} }

            controller.toggleRulers(nil)
            #expect(controller.scrollView.rulersVisible == true)
            #expect(controller.controls.rulers?.state == .on, "the View tab follows")
            controller.toggleGridlines(nil)
            #expect(controller.canvasView.showsGridlines == true)
            #expect(controller.scrollView.magnification == 1, "Paint leaves the zoom alone")

            let item = NSMenuItem(title: "Rulers", action: #selector(CanvasWindowController.toggleRulers(_:)), keyEquivalent: "")
            _ = controller.validateMenuItem(item)
            #expect(item.state == .on)
        }
    }
}
