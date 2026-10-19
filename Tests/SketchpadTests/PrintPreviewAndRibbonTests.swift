import AppKit
import Testing
import PaintCore
@testable import Sketchpad

/// Letter paper with half-inch margins: 540 × 720 points inside them.
private func letter(centered: Bool = true) -> NSPrintInfo {
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 612, height: 792)
    for margin in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] {
        info[keyPath: margin] = 36
    }
    info.isHorizontallyCentered = centered
    info.isVerticallyCentered = centered
    return info
}

@Suite struct PrintLayoutTests {
    @Test func aWidePictureRunsAcrossPages() {
        // 1000 × 800 pixels at 96 dpi print 750 × 600 points: two pages across, one down.
        let layout = PrintLayout(pixelWidth: 1000, pixelHeight: 800, dotsPerInch: 96, info: letter())
        #expect(layout.printable == NSRect(x: 36, y: 36, width: 540, height: 720))
        #expect(layout.pictureSize == NSSize(width: 750, height: 600))
        #expect((layout.columns, layout.rows, layout.pageCount) == (2, 1, 2))
        // Centered only the way it fits on one page: down, not across.
        #expect(layout.offset == NSPoint(x: 0, y: 60))
        #expect(layout.pictureFrame(onPage: 0) == NSRect(x: 36, y: 96, width: 750, height: 600))
        #expect(layout.pictureFrame(onPage: 1).origin == NSPoint(x: 36 - 540, y: 96))
    }

    @Test func pagesGoAcrossThenDown() {
        let info = letter(centered: false)
        info.scalingFactor = 2
        let layout = PrintLayout(pixelWidth: 500, pixelHeight: 500, dotsPerInch: 72, info: info)
        #expect((layout.columns, layout.rows) == (2, 2))
        #expect(layout.offset == .zero)
        #expect(layout.pictureFrame(onPage: 1).origin == NSPoint(x: 36 - 540, y: 36))
        #expect(layout.pictureFrame(onPage: 2).origin == NSPoint(x: 36, y: 36 - 720))
        #expect(layout.pictureFrame(onPage: 3).origin == NSPoint(x: 36 - 540, y: 36 - 720))
    }

    @Test func fitToOnePageScalesIntoTheMargins() {
        let info = letter()
        info.dictionary()[PageSetupAccessory.fitWideKey] = 1
        info.dictionary()[PageSetupAccessory.fitTallKey] = 1
        let layout = PrintLayout(pixelWidth: 1000, pixelHeight: 800, dotsPerInch: 96, info: info)
        #expect(layout.pageCount == 1)
        #expect(abs(layout.pictureSize.width - 540) < 0.001)
        #expect(abs(layout.offset.y - (720 - 432) / 2) < 0.001)
    }
}

@MainActor
@Suite(.serialized) struct PrintPreviewTests {
    private func previewMenuItem(_ controller: CanvasWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(CanvasWindowController.togglePrintPreview(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        return item
    }

    @Test func previewTakesThePicturesPlaceAndTheRibbon() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        ribbon.select(1)

        controller.togglePrintPreview(nil)
        #expect(controller.preview != nil)
        #expect(controller.scrollView.isHidden)
        #expect(ribbon.selectedTitle == localized("Print Preview"))
        #expect(ribbon.visibleGroups.map(\.title) == [localized("Print"), localized("Zoom"), localized("Preview"), ""])
        #expect(previewMenuItem(controller).state == .on)

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        controller.preview?.keyDown(with: escape)
        #expect(controller.preview == nil)
        #expect(!controller.scrollView.isHidden)
        #expect(ribbon.selectedTitle == localized("Home"))
        #expect(previewMenuItem(controller).state == .off)
    }

    @Test func pagesTurnOneOrTwoAtATime() throws {
        let document = CanvasDocument()
        let info = letter()
        info.scalingFactor = 2 // 800 × 600 pixels at 96 dpi, doubled: 1200 × 900 points, 3 × 2 pages
        document.printInfo = info
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        controller.togglePrintPreview(nil)
        defer { controller.closePrintPreview() }
        let preview = try #require(controller.preview)
        #expect(preview.layout.pageCount == 6)
        #expect(controller.controls.onePage?.isOn == true)
        #expect(controller.controls.previousPage?.isEnabled == false)
        #expect(controller.controls.nextPage?.isEnabled == true)

        controller.nextPreviewPage(nil)
        #expect(preview.page == 1)
        #expect(controller.controls.previousPage?.isEnabled == true)

        controller.showTwoPages(nil)
        #expect(preview.pagesShown == 2)
        #expect(controller.controls.twoPages?.isOn == true)
        controller.nextPreviewPage(nil)
        #expect(preview.page == 3)
        controller.previousPreviewPage(nil)
        #expect(preview.page == 1)

        // Zoomed in, one page shows; zooming back out brings the second back.
        controller.zoomIn(nil)
        #expect(preview.zoom == .actual)
        #expect(preview.pagesShown == 1)
        controller.zoomOut(nil)
        #expect(preview.pagesShown == 2)
    }

    @Test func clickingAPageStepsThroughTheZooms() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        controller.togglePrintPreview(nil)
        defer { controller.closePrintPreview() }
        let preview = try #require(controller.preview)
        var zooms: [PrintPreviewView.Zoom] = []
        for _ in 0..<3 {
            let paper = try #require(preview.paperRects.first?.rect)
            preview.click(at: NSPoint(x: paper.midX, y: paper.midY))
            zooms.append(preview.zoom)
        }
        #expect(zooms == [.actual, .double, .fit])
        preview.click(at: NSPoint(x: 1, y: 1)) // the gray around the page
        #expect(preview.zoom == .fit)
    }
}

@MainActor
@Suite(.serialized) struct RibbonCollapseTests {
    /// The collapsed groups at each width from wide to narrow, until the ribbon hides.
    private func collapsing(_ ribbon: RibbonView) -> [[String]] {
        var steps: [[String]] = []
        for width in stride(from: 3000, through: RibbonView.minimumWidth, by: -4) {
            ribbon.fit(width: CGFloat(width))
            guard !ribbon.isHiddenForSize else { break }
            let collapsed = ribbon.visibleGroups.filter(\.isCollapsed).map(\.title)
            if steps.last != collapsed { steps.append(collapsed) }
        }
        return steps
    }

    @Test func homeGroupsCollapseInPaintsOrder() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        ribbon.select(0)
        // Paint's scaling order, then Colors, the one other group that can collapse.
        let order = ["Clipboard", "Image", "Tools", "Shapes", "Colors"].map(localized)
        #expect(ribbon.collapseOrder.map(\.title) == order)
        #expect(collapsing(ribbon) == (0...5).map { Array(order.prefix($0)) })
        #expect(ribbon.isHiddenForSize, "too narrow even with every group collapsed")

        ribbon.fit(width: 3000)
        #expect(!ribbon.isHiddenForSize)
        #expect(ribbon.visibleGroups.allSatisfy { !$0.isCollapsed })
    }

    @Test func viewGroupsCollapseInPaintsOrder() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        ribbon.select(1)
        let order = ["Zoom", "Show or hide", "Display"].map(localized)
        let steps = collapsing(ribbon)
        #expect(steps == Array((0...steps.count - 1).map { Array(order.prefix($0)) }))
        #expect(steps.count >= 2)
        ribbon.select(0)
    }

    @Test func otherTabsCollapseInTheirOrder() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        ribbon.select(controller.controls.textTab)
        #expect(ribbon.collapseOrder.map(\.title) == ["Clipboard", "Colors", "Background", "Font"].map(localized))
        ribbon.select(controller.controls.previewTab)
        #expect(ribbon.collapseOrder.map(\.title) == ["Zoom", "Preview", "Print"].map(localized))
        ribbon.select(0)
    }

    @Test func ribbonHidesInSmallWindows() throws {
        let document = CanvasDocument()
        let controller = CanvasWindowController(document: document)
        defer { withExtendedLifetime(document) {} }
        let ribbon = try #require(controller.ribbon)
        ribbon.select(1)
        ribbon.fit(width: 3000, windowHeight: RibbonView.minimumHeight - 1)
        #expect(ribbon.isHiddenForSize)
        #expect(ribbon.fittingSize.height < 10)
        ribbon.fit(width: RibbonView.minimumWidth - 1)
        #expect(ribbon.isHiddenForSize)
        ribbon.fit(width: 3000)
        #expect(!ribbon.isHiddenForSize)
        #expect(ribbon.fittingSize.height > 100)
        ribbon.select(0)
    }
}
