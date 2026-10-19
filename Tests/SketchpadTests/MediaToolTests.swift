import AppKit
import CoreGraphics
import Testing
import PaintCore
@testable import Sketchpad

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// A canvas in an offscreen window, driven with synthesized mouse events.
@MainActor
private final class Canvas {
    let document = CanvasDocument()
    let state = EditorState()
    let view: CanvasView
    let window: NSWindow

    init() {
        view = CanvasView(document: document, state: state)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
    }

    var bitmap: Bitmap { document.bitmap }

    func send(_ type: NSEvent.EventType, at p: PixelPoint) {
        let location = view.convert(NSPoint(x: Double(p.x) + 0.5, y: Double(p.y) + 0.5), to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// A horizontal drag from x = 100 to 300 along y = 200 with a pen held at `pressure`.
    func penStroke(pressure: Double?) {
        send(.leftMouseDown, at: point(100, 200))
        guard case let .stroke(stroke) = view.drag else { return }
        view.extend(stroke, to: point(300, 200), constrained: false, pressure: pressure)
        send(.leftMouseUp, at: point(300, 200))
    }
}

/// A tablet drag event as a pen produces it.
private func tabletEvent(pressure: Double) -> NSEvent? {
    let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: .zero, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    event?.setDoubleValueField(.mouseEventPressure, value: pressure)
    return event.flatMap(NSEvent.init(cgEvent:))
}

@MainActor
@Suite(.serialized) struct MediaToolTests {
    @Test func sizesStartWherePaintStartsThem() {
        let state = EditorState()
        state.tool = .brush
        #expect(state.sizeOptions == [1, 3, 5, 8] && state.size == 3)
        state.brushKind = .calligraphy45
        #expect(state.sizeOptions == [3, 5, 8, 10] && state.size == 5)
        state.size = 10
        state.brushKind = .calligraphy135
        #expect(state.size == 10, "both calligraphy brushes share a size")
        state.brushKind = .airbrush
        #expect(state.sizeOptions == [4, 8, 16, 24] && state.size == 8)
        state.brushKind = .oil
        #expect(state.sizeOptions == [8, 16, 30, 40] && state.size == 30)
        state.brushKind = .naturalPencil
        #expect(state.sizeOptions == [4, 6, 8, 10] && state.size == 4)
        state.tool = .eraser
        #expect(state.size == 8)
        state.tool = .shape
        #expect(state.size == 5)
        state.tool = .pencil
        #expect(state.size == 1)
    }

    @Test func markerStrokeIsHalfTransparentAndUndoable() {
        let c = Canvas()
        c.state.tool = .brush
        c.state.brushKind = .marker
        c.send(.leftMouseDown, at: point(100, 100))
        c.send(.leftMouseDragged, at: point(200, 100))
        c.send(.leftMouseUp, at: point(200, 100))
        let middle = c.bitmap[point(150, 100)]
        #expect(middle.r == middle.g && (120...135).contains(Int(middle.r)), "half black: \(middle)")
        #expect(c.document.undoManager?.undoActionName == Tool.brush.title)
        c.view.undo(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(c.bitmap[point(150, 100)] == .white)
    }

    @Test func penPressureWidensTheOilBrush() {
        func painted(pressure: Double?) -> Bool {
            let c = Canvas()
            c.state.tool = .brush
            c.state.brushKind = .oil // 30 px: 20 px at no pressure, 40 px at full pressure
            c.penStroke(pressure: pressure)
            return c.bitmap[point(200, 217)] != .white
        }
        #expect(painted(pressure: 1))
        #expect(!painted(pressure: 0))
        #expect(!painted(pressure: nil), "a mouse draws the plain 30 px")
    }

    @Test func plainBrushesIgnorePressure() {
        func pixels(pressure: Double?) -> [UInt32] {
            let c = Canvas()
            c.state.tool = .brush
            c.state.brushKind = .normal
            c.penStroke(pressure: pressure)
            return c.bitmap.copyPixels()
        }
        #expect(pixels(pressure: 0.1) == pixels(pressure: 1))
    }

    @Test func pressureComesOnlyFromTabletEvents() throws {
        let pen = try #require(tabletEvent(pressure: 0.25))
        #expect(abs((CanvasView.pressure(of: pen) ?? 0) - 0.25) < 0.01)
        let mouse = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(CanvasView.pressure(of: mouse) == nil)
    }

    @Test func texturedOutlineAndLinesWithoutOutline() {
        let c = Canvas()
        c.state.tool = .shape
        c.state.shapeKind = .rectangle
        c.state.size = 8
        c.state.shapeOutline = .crayon
        c.state.shapeFill = .watercolor
        let style = c.view.shapeStyle(usesSecondary: false, kind: .rectangle)
        #expect(style.outlineMedium == .crayon && style.fillMedium == .watercolor)
        #expect(style.fill == .white, "fill is color 2")

        c.state.shapeOutline = .none
        let line = c.view.shapeStyle(usesSecondary: false, kind: .line)
        #expect(line.outline == .black && line.outlineMedium == nil, "a line is never invisible")
        #expect(line.fill == nil)
    }
}
