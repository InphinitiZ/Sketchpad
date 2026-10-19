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

    func send(_ type: NSEvent.EventType, at p: PixelPoint) {
        let location = canvas.convert(NSPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5), to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        default: canvas.mouseUp(with: event)
        }
        endEvent()
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
        #expect(h.document.undoManager?.undoActionName == "Move Selection")
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
        box.textView.string = "Ty"
        box.apply(style: style, color: .black, background: .white)

        let bitmap = Bitmap(width: 400, height: 200)
        box.render(into: bitmap, opaque: false, background: .white)

        // Find the inked rows.
        var inkRows: [Int] = []
        for y in 0..<bitmap.height where (0..<bitmap.width).contains(where: { bitmap[point($0, y)] != .white }) {
            inkRows.append(y)
        }
        let top = try #require(inkRows.first), bottom = try #require(inkRows.last)
        #expect(top >= 30 && bottom < 90, "text stays inside its box")
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
