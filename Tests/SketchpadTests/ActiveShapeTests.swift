import AppKit
import Testing
import PaintCore
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)
private let red = RGBA(237, 28, 36)
private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

@MainActor
@Suite(.serialized) struct ActiveShapeTests {
    /// A filled rectangle dragged from (100, 100) to (199, 149), still active.
    private func stageWithRectangle() -> Stage {
        let s = Stage()
        s.state.tool = .shape
        s.state.shapeKind = .rectangle
        s.state.shapeFill = .solid
        s.state.secondary = blue
        s.drag(from: point(100, 100), to: point(199, 149))
        return s
    }

    @Test func aDrawnShapeKeepsItsHandles() throws {
        let s = stageWithRectangle()
        let shape = try #require(s.canvas.activeShape)
        #expect(shape.box == PixelRect(x: 100, y: 100, width: 100, height: 50))
        #expect(s.canvas.trackers.last?.target == .shape && s.canvas.trackers.last?.handles.count == 8)
        #expect(s.document.undoManager?.canUndo == false, "nothing is recorded until it is placed")
    }

    @Test func draggingInsideMovesTheShapeWithoutATrail() {
        let s = stageWithRectangle()
        s.drag(from: point(150, 125), to: point(350, 325))
        #expect(s.canvas.activeShape?.box == PixelRect(x: 300, y: 300, width: 100, height: 50))
        #expect(s.bitmap[point(150, 125)] == .white, "the old place is clean")
        #expect(s.bitmap[point(350, 325)] == blue)
    }

    @Test func handlesResizeDownToEightPixels() throws {
        let s = stageWithRectangle()
        let tracker = try #require(s.canvas.trackers.last)
        s.canvas.beginHandleDrag(tracker, .right, at: CGPoint(x: 200, y: 125))
        s.canvas.dragHandle(to: CGPoint(x: 260, y: 125))
        #expect(s.canvas.activeShape?.box.width == 160)
        s.canvas.dragHandle(to: CGPoint(x: 0, y: 125))
        #expect(s.canvas.activeShape?.box == PixelRect(x: 100, y: 100, width: 8, height: 50), "never flips, never under 8 px")
        s.canvas.endHandleDrag()
    }

    @Test func styleChangesRestyleTheActiveShape() {
        let s = stageWithRectangle()
        s.state.secondary = red
        #expect(s.bitmap[point(150, 125)] == red, "the fill follows color 2")
        s.state.shapeFill = .none
        #expect(s.bitmap[point(150, 125)] == .white)
    }

    @Test func clickingElsewherePlacesItAndStartsANewOne() {
        let s = stageWithRectangle()
        s.drag(from: point(400, 400), to: point(450, 450))
        #expect(s.bitmap[point(150, 125)] == blue, "the first rectangle stays")
        #expect(s.canvas.activeShape?.box == PixelRect(x: 400, y: 400, width: 51, height: 51))
        #expect(s.document.undoManager?.undoActionName == ShapeKind.rectangle.title)
    }

    @Test func escapeAndDeleteDiscard() {
        let s = stageWithRectangle()
        s.press("\u{1b}", keyCode: 53)
        #expect(s.canvas.activeShape == nil)
        #expect(s.bitmap[point(150, 125)] == .white)
        #expect(s.document.undoManager?.canUndo == false)

        let t = stageWithRectangle()
        t.canvas.delete(nil)
        #expect(t.bitmap[point(150, 125)] == .white)
    }

    @Test func returnAndToolChangesPlaceIt() {
        let s = stageWithRectangle()
        s.press("\r", keyCode: 36)
        #expect(s.canvas.activeShape == nil)
        #expect(s.bitmap[point(150, 125)] == blue)

        let t = stageWithRectangle()
        t.state.tool = .pencil
        #expect(t.canvas.activeShape == nil)
        #expect(t.document.undoManager?.canUndo == true)
    }

    @Test func rotateTurnsTheShapeNotThePicture() {
        let s = Stage()
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 0, y: 0, width: 10, height: 10)), with: red)
        s.state.tool = .shape
        s.state.shapeKind = .rightTriangle
        s.state.shapeFill = .solid
        s.state.secondary = blue
        s.drag(from: point(100, 100), to: point(199, 139))
        s.canvas.rotateRight(nil)
        #expect(s.canvas.activeShape?.box == PixelRect(x: 130, y: 70, width: 40, height: 100))
        #expect(s.canvas.activeShape?.orientation.quarterTurns == 1)
        #expect(s.bitmap[point(5, 5)] == red, "the picture is untouched")
        s.canvas.flipHorizontal(nil)
        #expect(s.canvas.activeShape?.orientation.flippedVertically == true, "a flip after a quarter turn mirrors the turned shape")
    }

    @Test func invertColorInvertsTheShapesColors() {
        let s = stageWithRectangle()
        s.canvas.invertColor(nil)
        #expect(s.bitmap[point(150, 125)] == RGBA(192, 183, 51))
        #expect(s.bitmap[point(400, 400)] == .white)
    }

    @Test func lineEndsMoveFreely() throws {
        let s = Stage()
        s.state.tool = .shape
        s.state.shapeKind = .line
        s.drag(from: point(100, 100), to: point(200, 150))
        let tracker = try #require(s.canvas.trackers.last)
        #expect(tracker.handles == [.topLeft, .bottomRight])
        s.canvas.beginHandleDrag(tracker, .topLeft, at: CGPoint(x: 100, y: 100))
        s.canvas.dragHandle(to: CGPoint(x: 300, y: 300))
        s.canvas.endHandleDrag()
        let ends = try #require(s.canvas.activeShape?.points)
        #expect(ends[0] == CGPoint(x: 300.5, y: 300.5) && ends[1] == CGPoint(x: 200.5, y: 150.5), "the end crossed over the other")
        #expect(s.bitmap[point(250, 225)] != .white)
        #expect(s.bitmap[point(150, 125)] == .white)
    }

    @Test func rightClickOnTheShapeOffersItsMenu() {
        let s = stageWithRectangle()
        let titles = s.canvas.shapeMenu().items.map(\.title)
        #expect(titles == [localized("Delete"), localized("Paste"), "", localized("Rotate"), localized("Invert Color"), "", localized("Outline"), localized("Fill")])
    }

    @Test func polygonClosesWithinTenPixelsOfItsStart() {
        let s = Stage()
        s.state.tool = .shape
        s.state.shapeKind = .polygon
        s.drag(from: point(100, 100), to: point(300, 100))
        s.send(.leftMouseDown, at: point(300, 300))
        s.send(.leftMouseUp, at: point(300, 300))
        s.send(.leftMouseDown, at: point(108, 109))
        s.send(.leftMouseUp, at: point(108, 109))
        #expect(s.canvas.pendingShape == nil)
        #expect(s.canvas.activeShape?.kind == .polygon)
        #expect(s.canvas.activeShape?.points.count == 3)
    }
}
