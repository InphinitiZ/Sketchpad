import AppKit
import Testing
import PaintCore
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)
private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

@MainActor
@Suite(.serialized) struct SelectionBehaviorTests {
    /// A 10×10 blue square at (10, 10), selected.
    private func stageWithSelectedSquare() -> Stage {
        let s = Stage()
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 10, height: 10)), with: blue)
        s.state.tool = .select
        s.drag(from: point(10, 10), to: point(19, 19))
        return s
    }

    @Test func optionDragLeavesTheOriginalBehind() {
        let s = stageWithSelectedSquare()
        s.drag(from: point(15, 15), to: point(55, 15), modifiers: .option)
        #expect(s.bitmap[point(15, 15)] == blue, "the original stays")
        #expect(s.bitmap[point(55, 15)] == blue, "and a copy moved")
        s.canvas.commitSelection()
        s.settle()
        #expect(s.document.undoManager?.undoActionName == localized("Copy Selection"))
        s.undo()
        #expect(s.bitmap[point(55, 15)] == .white)
        #expect(s.bitmap[point(15, 15)] == blue)
    }

    @Test func shiftDragSmearsATrail() {
        let s = stageWithSelectedSquare()
        s.send(.leftMouseDown, at: point(15, 15), modifiers: .shift)
        for x in stride(from: 20, through: 60, by: 5) { s.send(.leftMouseDragged, at: point(x, 15), modifiers: .shift) }
        s.send(.leftMouseUp, at: point(60, 15), modifiers: .shift)
        for x in [10, 30, 45, 64] { #expect(s.bitmap[point(x, 15)] == blue, "trail at \(x)") }
        #expect(s.bitmap[point(65, 15)] == .white)
    }

    @Test func aSelectionCannotLeaveTheCanvas() {
        let s = stageWithSelectedSquare()
        s.drag(from: point(15, 15), to: point(-500, -500))
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: -10, y: -10, width: 10, height: 10), "its far edge stops at the canvas edge")
        let other = stageWithSelectedSquare()
        other.drag(from: point(15, 15), to: point(5000, 5000))
        #expect(other.canvas.selection?.mask.rect.x == 800 && other.canvas.selection?.mask.rect.y == 600)
    }

    @Test func invertSelectionSelectsTheRest() throws {
        let s = stageWithSelectedSquare()
        s.canvas.invertSelection(nil)
        let mask = try #require(s.canvas.selection?.mask)
        #expect(mask.rect == s.bitmap.bounds)
        #expect(!mask.contains(point(15, 15)) && mask.contains(point(5, 5)) && mask.contains(point(700, 500)))
        s.canvas.delete(nil)
        s.settle()
        #expect(s.bitmap[point(15, 15)] == blue)
    }

    @Test func invertColorActsOnTheSelectionOnly() {
        let s = stageWithSelectedSquare()
        s.canvas.invertColor(nil)
        s.canvas.commitSelection()
        s.settle()
        #expect(s.bitmap[point(15, 15)] == RGBA(192, 183, 51))
        #expect(s.bitmap[point(100, 100)] == .white)
        #expect(s.document.undoManager?.undoActionName == localized("Invert Color"))
    }

    @Test func sTogglesBetweenTheSelectionShapes() {
        let s = Stage()
        s.state.tool = .pencil
        s.press("s")
        #expect(s.state.tool == .select)
        s.press("s")
        #expect(s.state.tool == .freeFormSelect)
        s.press("s")
        #expect(s.state.tool == .select)
    }

    @Test func contextMenuHasPaintsCommands() {
        let s = stageWithSelectedSquare()
        let titles = s.canvas.selectionMenu().items.map(\.title)
        #expect(titles == [
            localized("Cut"), localized("Copy"), localized("Paste"), "",
            localized("Crop"), localized("Select All"), localized("Invert Selection"), localized("Delete"), "",
            localized("Rotate"), localized("Resize"), localized("Invert Color"),
        ])
    }

    @Test func freeFormSelectionShowsItsBox() {
        let s = Stage()
        s.state.tool = .freeFormSelect
        s.send(.leftMouseDown, at: point(10, 10))
        for p in [point(50, 12), point(40, 60), point(12, 40)] { s.send(.leftMouseDragged, at: p) }
        s.send(.leftMouseUp, at: point(12, 40))
        #expect(s.canvas.trackers.contains { $0.target == .selection && $0.rect == s.canvas.selection?.mask.rect.cgRect })
    }
}
