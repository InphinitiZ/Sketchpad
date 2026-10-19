import AppKit
import Testing
import PaintCore
import UniformTypeIdentifiers
@testable import Sketchpad

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

@MainActor
@Suite(.serialized) struct FileAndSettingsTests {
    @Test func bitmapDepthsWriteReadableFiles() throws {
        let grid = PixelGrid(width: 5, height: 3, pixels: [
            RGBA.black, .white, RGBA(237, 28, 36), RGBA(0, 162, 232), RGBA(34, 177, 76),
            .white, .black, .white, .black, .white,
            RGBA(255, 242, 0), RGBA(255, 242, 0), .black, .white, RGBA(128, 128, 128),
        ].map(\.packed))
        for depth in BitmapDepth.allCases {
            let data = ImageCodec.encodeBMP(grid, depth: depth, dotsPerInch: 120)
            #expect(data.prefix(2) == Data([0x42, 0x4D]))
            #expect(Int(data[28]) == depth.rawValue, "bits per pixel")
            let decoded = try #require(ImageCodec.decodeWithResolution(data), "\(depth)")
            #expect(decoded.image.width == 5 && decoded.image.height == 3)
            #expect(abs(decoded.dotsPerInch - 120) < 1)
            let bitmap = Bitmap(image: decoded.image)
            #expect(bitmap[point(0, 0)] == .black && bitmap[point(1, 0)] == .white, "\(depth) keeps black and white")
            if depth == .trueColor || depth == .twoHundredFiftySixColors {
                #expect(bitmap[point(2, 0)] == RGBA(237, 28, 36), "\(depth) keeps red exactly")
            }
            if depth == .sixteenColors {
                #expect(bitmap[point(2, 0)] == RGBA(255, 0, 0), "nearest VGA color")
            }
        }
    }

    @Test func colorLossIsDetectedPerDepth() {
        let twoColors = PixelGrid(width: 2, height: 1, pixels: [RGBA.black.packed, RGBA.white.packed])
        #expect(!twoColors.losesColors(at: .monochrome))
        let red = PixelGrid(width: 2, height: 1, pixels: [RGBA.black.packed, RGBA(237, 28, 36).packed])
        #expect(red.losesColors(at: .monochrome))
        #expect(!red.losesColors(at: .sixteenColors))
        let many = PixelGrid(width: 300, height: 1, pixels: (0..<300).map { RGBA(UInt8($0 % 256), UInt8($0 / 256), 0).packed })
        #expect(many.losesColors(at: .twoHundredFiftySixColors))
        #expect(!many.losesColors(at: .trueColor))
    }

    @Test func gifAndBitmapSavesWarnOnlyWhenColorsWouldGo() {
        let document = CanvasDocument()
        #expect(!document.savingLosesColors(as: .gif), "a blank picture fits in 256 colors")
        document.bitmapDepth = .monochrome
        #expect(!document.savingLosesColors(as: .bmp))
        document.bitmap.fill(SelectionMask(rect: PixelRect(x: 0, y: 0, width: 4, height: 4)), with: RGBA(237, 28, 36))
        #expect(document.savingLosesColors(as: .bmp))
        #expect(!document.savingLosesColors(as: .png))
        let data = try? document.data(ofType: UTType.bmp.identifier)
        #expect(data.map { Int($0[28]) } == 1, "the chosen depth is written")
    }

    @Test func freshSettingsMatchPaintsDefaults() {
        withFreshPreferences {
            #expect(Preferences.unit == .pixels, "a missing unit is pixels, not the 0 of inches")
            #expect(Preferences.showStatusBar && !Preferences.showRulers && !Preferences.showGrid)
        }
    }

    @Test func viewOptionsAndUnitsAreRemembered() {
        withFreshPreferences {
            Preferences.showRulers = true
            Preferences.showStatusBar = false
            Preferences.unit = .inches
            let document = CanvasDocument()
            let controller = CanvasWindowController(document: document)
            #expect(controller.scrollView.rulersVisible)
            #expect(controller.statusBar.isHidden)
            controller.updateStatus()
            #expect(controller.statusBar.canvasLabel.stringValue == "8.33 × 6.25" + localized("in"), "800 × 600 px at 96 DPI")
            controller.toggleStatusBar(nil)
            #expect(Preferences.showStatusBar)
        }
    }

    @Test func newPicturesTakeTheLastSize() {
        withFreshPreferences {
            Preferences.newPictureSize = (320, 240)
            #expect(CanvasDocument().bitmap.width == 320)
            Preferences.newPictureSize = (6000, 240)
            #expect(CanvasDocument().bitmap.width == 800, "Paint ignores sizes over 5000")
        }
    }

    @Test func textSettingsCarryOver() {
        withFreshPreferences {
            let state = EditorState()
            state.textStyle.points = 24
            state.textStyle.strikethrough = true
            let next = EditorState()
            #expect(next.textStyle.points == 24 && next.textStyle.strikethrough)
        }
    }
}
