import AppKit
import Testing
import PaintCore
@testable import Sketchpad

private let blue = RGBA(63, 72, 204)
private let red = RGBA(237, 28, 36)
private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// Behaviors decompiled from Paint (see the README's list).
@MainActor
@Suite(.serialized) struct ParityTests {
    @Test func rightEraserTurnsOnlyColor1IntoColor2() {
        let s = Stage()
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 100, y: 95, width: 20, height: 10)), with: .black)
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 140, y: 95, width: 20, height: 10)), with: red)
        s.state.tool = .eraser
        s.state.secondary = blue
        s.send(.rightMouseDown, at: point(90, 100))
        s.send(.rightMouseDragged, at: point(170, 100))
        s.send(.rightMouseUp, at: point(170, 100))
        #expect(s.bitmap[point(110, 100)] == blue, "Color 1 (black) became Color 2")
        #expect(s.bitmap[point(150, 100)] == red, "other colors are left alone")
        #expect(s.bitmap[point(95, 100)] == .white, "white was not Color 1 either")
    }

    @Test func pencilWithShiftKeepsItsFirstDirection() {
        let s = Stage()
        s.state.tool = .pencil
        s.send(.leftMouseDown, at: point(100, 100))
        s.send(.leftMouseDragged, at: point(140, 104), modifiers: .shift)
        s.send(.leftMouseDragged, at: point(180, 130), modifiers: .shift)
        s.send(.leftMouseUp, at: point(180, 130), modifiers: .shift)
        #expect(s.bitmap[point(180, 100)] == .black, "locked to horizontal")
        #expect(s.bitmap[point(180, 130)] == .white)
    }

    @Test func pickerShowsTheColorLiveAndReturnsOnRelease() {
        let s = Stage()
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 0, y: 0, width: 10, height: 10)), with: red)
        s.bitmap.fill(SelectionMask(rect: PixelRect(x: 20, y: 0, width: 10, height: 10)), with: blue)
        s.state.tool = .fill
        s.state.tool = .picker
        s.send(.leftMouseDown, at: point(5, 5))
        #expect(s.state.primary == red)
        #expect(s.state.tool == .picker, "still picking while the button is down")
        s.send(.leftMouseDragged, at: point(25, 5))
        #expect(s.state.primary == blue)
        s.send(.leftMouseUp, at: point(25, 5))
        #expect(s.state.tool == .fill, "back to the tool before")
    }

    @Test func sizeStepsAndSelectionDoubling() {
        let s = Stage()
        s.state.tool = .brush
        #expect(s.state.size == 3)
        s.canvas.largerSize(nil)
        #expect(s.state.size == 5)
        s.canvas.smallerSize(nil)
        s.canvas.smallerSize(nil)
        s.canvas.smallerSize(nil)
        #expect(s.state.size == 1, "stops at the smallest")

        s.state.tool = .select
        s.canvas.select(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 30, height: 20)))
        s.canvas.largerSize(nil)
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: 10, y: 10, width: 60, height: 40))
        s.canvas.smallerSize(nil)
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: 10, y: 10, width: 30, height: 20))
    }

    @Test func tabPicksAHandleForTheArrowKeys() {
        let s = Stage()
        s.state.tool = .select
        s.canvas.select(SelectionMask(rect: PixelRect(x: 10, y: 10, width: 30, height: 20)))
        s.press("\t", keyCode: 48)
        #expect(s.canvas.keyboardHandle == .topLeft)
        s.press("\t", keyCode: 48)
        s.press("\t", keyCode: 48)
        s.press("\t", keyCode: 48)
        #expect(s.canvas.keyboardHandle == .right)
        s.press("", keyCode: 124)
        s.press("", keyCode: 125)
        #expect(s.canvas.selection?.mask.rect == PixelRect(x: 10, y: 10, width: 31, height: 20), "a side handle moves only across")
        s.press("\t", keyCode: 48, modifiers: .shift)
        #expect(s.canvas.keyboardHandle == .topRight)
    }

    @Test func textBoxMovesByItsBorder() {
        let s = Stage()
        s.state.tool = .text
        s.drag(from: point(50, 50), to: point(200, 90))
        let start = s.canvas.textBox?.textView.frame.origin
        s.canvas.beginTextBoxMove(at: CGPoint(x: 49, y: 49))
        s.canvas.dragHandle(to: CGPoint(x: 99, y: 69))
        s.canvas.endHandleDrag()
        #expect(s.canvas.textBox?.textView.frame.origin == start.map { CGPoint(x: $0.x + 50, y: $0.y + 20) })
    }

    @Test func formatMenuTogglesTheTextStyle() {
        withFreshPreferences {
            let document = CanvasDocument()
            let controller = CanvasWindowController(document: document)
            defer {
                withExtendedLifetime(document) {}
            }
            let bold = NSMenuItem(title: "", action: #selector(CanvasWindowController.toggleBold(_:)), keyEquivalent: "")
            #expect(!controller.validateMenuItem(bold), "only for the text tool")
            controller.state.tool = .text
            #expect(controller.validateMenuItem(bold))
            controller.toggleBold(nil)
            #expect(controller.state.textStyle.bold)
            #expect(controller.controls.bold?.isOn == true)
        }
    }

    @Test func eraserPointerIsItsSquareAtTheZoom() {
        let state = EditorState()
        state.tool = .eraser
        let atActualSize = ToolCursors.cursor(for: state, magnification: 1).image.size
        let zoomed = ToolCursors.cursor(for: state, magnification: 4).image.size
        #expect(atActualSize.width == 10, "8 px plus a pixel of margin each side")
        #expect(zoomed.width == 34)
        state.tool = .select
        #expect(ToolCursors.cursor(for: state, magnification: 1) == .crosshair)
    }

    @Test func zoomSliderFollowsPaint() {
        #expect(StatusBarView.zoomLevels == [0.125, 0.25, 0.5, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(StatusBarView.sliderPosition(for: 1) == 50)
        #expect(StatusBarView.sliderPosition(for: 8) == 100)
        #expect(StatusBarView.sliderPosition(for: 0.125) == 0)
        #expect(StatusBarView.nearestPreset(to: StatusBarView.zoom(forSliderPosition: 72)) == 4)
        #expect(StatusBarView.percent(0.125) == "12.5")
    }

    @Test func thumbnailShowsOnlyWhileZoomedIn() {
        withFreshPreferences {
            let document = CanvasDocument()
            let controller = CanvasWindowController(document: document)
            defer {
                controller.window?.close()
            }
            controller.toggleThumbnail(nil)
            #expect(!controller.thumbnailIsShowing, "not at 100%")
            controller.setZoom(2, centeredAt: nil)
            #expect(controller.thumbnailIsShowing)
            controller.setZoom(1, centeredAt: nil)
            #expect(!controller.thumbnailIsShowing)
        }
    }

    @Test func zoomingPlacesTheSelection() {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        controller.state.tool = .select
        controller.canvasView.select(SelectionMask(rect: PixelRect(x: 0, y: 0, width: 10, height: 10)))
        controller.zoomIn(nil)
        #expect(controller.canvasView.selection == nil)
        #expect(controller.scrollView.magnification == 2)
    }

    @Test func fitToPagesScalesThePrintout() {
        let info = NSPrintInfo()
        info.dictionary()[PageSetupAccessory.fitWideKey] = 1
        info.dictionary()[PageSetupAccessory.fitTallKey] = 1
        let page = info.imageablePageBounds.size
        let scale = PageSetupAccessory.fitScale(for: NSSize(width: page.width * 4, height: page.height), info: info)
        #expect(scale == 0.25)
        info.dictionary()[PageSetupAccessory.fitWideKey] = 0
        #expect(PageSetupAccessory.fitScale(for: NSSize(width: 10, height: 10), info: info) == nil)
    }
}

@Suite struct GridlineTests {
    @Test func spacingFollowsZoomAndUnit() {
        let zooms: [CGFloat] = [8, 4, 3, 2, 1, 0.5, 0.25, 0.125]
        #expect(zooms.map { Gridlines.spacing(zoom: $0, unit: .pixels) } == [1, 1, 5, 5, 10, 20, 50, 100])
        #expect(zooms.map { Gridlines.spacing(zoom: $0, unit: .inches) } == [1, 1, 0.1, 0.1, 0.25, 0.5, 1, 2])
        #expect(zooms.map { Gridlines.spacing(zoom: $0, unit: .centimeters) } == [1, 1, 0.25, 0.25, 0.5, 1, 2, 5])
        #expect(Gridlines.spacing(zoom: 0.05, unit: .pixels) == 200)
        #expect(Gridlines.step(zoom: 1, unit: .inches, dotsPerInch: 96) == 24, "a quarter inch at 96 DPI")
    }

    @Test func dotsAreOpaqueFrom400Percent() {
        #expect(Gridlines.colors(zoom: 4).0.alpha == 1)
        #expect(Gridlines.colors(zoom: 2).0.alpha == 0.5)
        #expect(Gridlines.colors(zoom: 2).1.alpha == 0.25)
    }
}
