import AppKit
import Testing
import PaintCore
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)
private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// A document shown the way the app shows it: canvas inside the workspace inside a scroll view.
@MainActor
private final class Workspace {
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

    func tracker(_ target: TrackerTarget) -> Tracker? {
        canvas.trackers.first { $0.target == target }
    }

    /// Drags `handle` of `target` by (dx, dy) canvas pixels.
    func dragHandle(_ target: TrackerTarget, _ handle: Handle, by dx: Int, _ dy: Int) {
        guard let tracker = tracker(target) else { return }
        let start = CGPoint(x: tracker.rect.minX + tracker.rect.width * handle.anchor.x,
                            y: tracker.rect.minY + tracker.rect.height * handle.anchor.y)
        canvas.beginHandleDrag(tracker, handle, at: start)
        canvas.dragHandle(to: CGPoint(x: start.x + CGFloat(dx), y: start.y + CGFloat(dy)))
        canvas.endHandleDrag()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    func select(_ rect: PixelRect) {
        state.tool = .select
        canvas.select(SelectionMask(rect: rect))
    }
}

@MainActor
@Suite(.serialized) struct HandleTests {
    @Test func selectionHasEightHandlesAndTheCanvasThree() {
        let w = Workspace()
        #expect(w.canvas.trackers.map(\.target) == [.canvas])
        #expect(w.tracker(.canvas)?.handles == [.right, .bottom, .bottomRight])
        w.select(PixelRect(x: 10, y: 10, width: 20, height: 10))
        #expect(w.tracker(.selection)?.handles.count == 8)
    }

    @Test func draggingASelectionHandleStretchesThePixels() {
        let w = Workspace()
        w.bitmap.fill(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 10, height: 10)), with: blue)
        w.select(PixelRect(x: 10, y: 10, width: 20, height: 10))
        w.dragHandle(.selection, .bottomRight, by: 20, 10)

        #expect(w.canvas.selection?.mask.rect == PixelRect(x: 10, y: 10, width: 40, height: 20))
        #expect(w.bitmap[point(29, 29)] == blue, "the blue square doubled in size")
        #expect(w.bitmap[point(30, 15)] == .white)

        w.canvas.commitSelection()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(w.document.undoManager?.undoActionName == localized("Resize"))
        w.canvas.undo(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(w.bitmap[point(29, 29)] == .white)
        #expect(w.bitmap[point(19, 19)] == blue)
    }

    @Test func leftHandleKeepsTheRightEdgeAndStopsAtOnePixel() {
        let w = Workspace()
        w.select(PixelRect(x: 100, y: 100, width: 50, height: 30))
        w.dragHandle(.selection, .left, by: -20, 0)
        #expect(w.canvas.selection?.mask.rect == PixelRect(x: 80, y: 100, width: 70, height: 30))
        w.dragHandle(.selection, .left, by: 500, 0)
        #expect(w.canvas.selection?.mask.rect == PixelRect(x: 149, y: 100, width: 1, height: 30))
    }

    @Test func canvasHandleGrowsTheCanvasWithColor2() {
        let w = Workspace()
        w.state.secondary = blue
        w.dragHandle(.canvas, .bottomRight, by: 100, 50)
        #expect(w.bitmap.width == 900 && w.bitmap.height == 650)
        #expect(w.bitmap[point(850, 300)] == blue)
        #expect(w.bitmap[point(10, 10)] == .white)
        #expect(w.document.undoManager?.undoActionName == localized("Resize Canvas"))

        w.dragHandle(.canvas, .right, by: -850, 0)
        #expect(w.bitmap.width == 50 && w.bitmap.height == 650, "the right handle only changes the width")
        w.canvas.undo(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        #expect(w.bitmap.width == 900)
    }

    @Test func handlesAreHitOnlyOnTheirSquares() throws {
        let w = Workspace()
        let handles = w.workspace.handlesView
        let canvas = try #require(w.tracker(.canvas))
        let corner = handles.frame(of: .bottomRight, on: canvas)
        #expect(handles.handle(at: NSPoint(x: corner.midX, y: corner.midY))?.1 == .bottomRight)
        #expect(handles.handle(at: handles.convert(NSPoint(x: 400, y: 300), from: w.canvas)) == nil)
        #expect(handles.hitTest(w.workspace.convert(NSPoint(x: 400, y: 300), from: w.canvas)) == nil, "clicks pass through to the canvas")
    }

    @Test func textBoxHandlesResizeTheBox() {
        let w = Workspace()
        w.state.tool = .text
        w.canvas.drag = .textBox(start: point(10, 10), end: point(110, 40))
        w.canvas.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: w.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!)
        let before = w.canvas.textBox?.textView.frame.width ?? 0
        w.dragHandle(.textBox, .right, by: 40, 0)
        #expect(w.canvas.textBox?.textView.frame.width == before + 40)
    }
}
