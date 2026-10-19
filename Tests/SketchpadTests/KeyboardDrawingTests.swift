import AppKit
import Testing
import PaintCore
@testable import Sketchpad

@MainActor
@Suite struct ArrowKeyMotionTests {
    @Test func speedRampsFromOneToFive() {
        let elapsed = [0, 99, 100, 574, 575, 1049, 1050, 1525, 2000, 5000]
        #expect(elapsed.map(ArrowKeyMotion.distance(afterMilliseconds:)) == [0, 0, 1, 1, 2, 2, 3, 4, 5, 5])
    }

    @Test func firstPressStepsOnceThenTheTimerTakesOver() {
        var steps: [ArrowKeyMotion.Step] = []
        let motion = ArrowKeyMotion { steps.append($0) }
        defer { motion.stop() }

        #expect(motion.keyDown(124, at: 10))
        #expect(steps == [.init(dx: 1, dy: 0)], "one step at once, Shift or not")
        #expect(motion.keyDown(124, at: 10.03))
        motion.tick(at: 10.05, modifiers: [])
        #expect(steps.count == 1, "repeats are ignored and nothing moves for 100 ms")

        motion.tick(at: 10.2, modifiers: .shift)
        #expect(steps.last == .init(dx: 2, dy: 0), "Shift doubles")
        #expect(motion.keyDown(125, at: 10.3))
        #expect(steps.count == 2, "a second arrow joins the timer's direction")
        motion.tick(at: 12.5, modifiers: .option)
        #expect(steps.last == .init(dx: 5, dy: 5, scrolls: true), "full speed, scrolling with Option")

        #expect(motion.keyUp(124))
        #expect(motion.isMoving)
        #expect(motion.keyUp(125))
        #expect(!motion.isMoving)
        #expect(!motion.keyDown(49), "only the arrows")
    }

    @Test func opposingArrowsStop() {
        var steps: [ArrowKeyMotion.Step] = []
        let motion = ArrowKeyMotion { steps.append($0) }
        defer { motion.stop() }
        _ = motion.keyDown(123, at: 0)
        _ = motion.keyDown(124, at: 0)
        motion.tick(at: 1, modifiers: [])
        #expect(!motion.isMoving)
        #expect(steps.count == 1)
    }
}

@MainActor
@Suite(.serialized) struct KeyboardDrawingTests {
    @Test func arrowsMoveThePointerAndSpaceDraws() {
        let s = Stage()
        s.state.tool = .pencil
        s.movePointer(to: PixelPoint(x: 10, y: 10))
        s.keyDown(" ", keyCode: 49)
        s.canvas.keyboardStep(.init(dx: 5, dy: 0))
        #expect(s.pointerPixel == PixelPoint(x: 15, y: 10))
        s.canvas.keyboardStep(.init(dx: 0, dy: 3))
        s.keyUp(" ", keyCode: 49)
        #expect(!s.canvas.isKeyboardButtonDown)
        for x in 10...15 {
            #expect(s.bitmap[PixelPoint(x: x, y: 10)] == s.state.primary)
        }
        for y in 10...13 {
            #expect(s.bitmap[PixelPoint(x: 15, y: y)] == s.state.primary)
        }
        #expect(s.bitmap[PixelPoint(x: 9, y: 10)] == .white)
    }

    @Test func aPointerElsewhereJumpsBackFirst() {
        let s = Stage()
        s.state.tool = .pencil
        s.pointerLocation = NSPoint(x: -500, y: -500)
        s.canvas.keyboardStep(.init(dx: 1, dy: 0))
        #expect(s.pointerPixel == PixelPoint(x: 0, y: 0), "back to where the keys left it, without moving")
        s.canvas.keyboardStep(.init(dx: 4, dy: 2))
        #expect(s.pointerPixel == PixelPoint(x: 4, y: 2))
        #expect(s.bitmap[PixelPoint(x: 0, y: 0)] == .white, "moving alone draws nothing")
    }

    @Test func thePointerStaysOnTheVisiblePicture() {
        let s = Stage()
        s.state.tool = .pencil
        s.movePointer(to: PixelPoint(x: 790, y: 590))
        s.canvas.keyboardStep(.init(dx: 50, dy: 50))
        // Paint keeps the pointer 2 points in from the right and bottom of what is visible.
        #expect(s.pointerPixel == PixelPoint(x: 798, y: 598))
        s.canvas.keyboardStep(.init(dx: -900, dy: -900))
        #expect(s.pointerPixel == PixelPoint(x: 0, y: 0))
    }

    @Test func arrowsMoveTheSelectionBeforeThePointer() {
        let s = Stage()
        s.state.tool = .select
        s.movePointer(to: PixelPoint(x: 100, y: 100))
        s.canvas.select(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 30, height: 20)))
        s.press("", keyCode: 124)
        s.press("", keyCode: 125, modifiers: .shift)
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: 11, y: 11, width: 30, height: 20), "a single press moves 1, Shift or not")
        #expect(s.pointerPixel == PixelPoint(x: 100, y: 100))
    }

    @Test func returnPlacesTheSelection() {
        let s = Stage()
        s.state.tool = .select
        s.canvas.select(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 30, height: 20)))
        s.press("", keyCode: 124)
        s.press("\r", keyCode: 36)
        #expect(s.canvas.selection == nil)
        s.undo()
        #expect(s.canvas.selection == nil, "placing it was one undo step with the move")
    }

    @Test func spaceDragsASelectionRectangle() {
        let s = Stage()
        s.state.tool = .select
        s.movePointer(to: PixelPoint(x: 20, y: 20))
        s.keyDown(" ", keyCode: 49)
        s.canvas.keyboardStep(.init(dx: 30, dy: 10))
        s.keyUp(" ", keyCode: 49)
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: 20, y: 20, width: 31, height: 11), "as a mouse drag from 20,20 to 50,30")
    }

    @Test func optionArrowsScrollThePicture() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        controller.setZoom(4, centeredAt: nil)
        let clip = controller.scrollView.contentView
        let before = clip.bounds.origin
        controller.canvasView.keyboardStep(.init(dx: 20, dy: 40, scrolls: true))
        #expect(clip.bounds.origin.x - before.x == 5)
        #expect(clip.bounds.origin.y - before.y == 10)
    }
}
