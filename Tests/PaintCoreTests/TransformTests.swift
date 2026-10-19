import Testing
@testable import PaintCore

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// A 3×2 grid holding 1…6:
///   1 2 3
///   4 5 6
private let grid = PixelGrid(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])

@Suite struct TransformTests {
    @Test func flips() {
        #expect(grid.applying(.flipHorizontal, background: 0).pixels == [3, 2, 1, 6, 5, 4])
        #expect(grid.applying(.flipVertical, background: 0).pixels == [4, 5, 6, 1, 2, 3])
    }

    @Test func rotations() {
        let clockwise = grid.applying(.rotate(.clockwise), background: 0)
        #expect(clockwise.width == 2 && clockwise.height == 3)
        #expect(clockwise.pixels == [4, 1, 5, 2, 6, 3])
        #expect(grid.applying(.rotate(.counterclockwise), background: 0).pixels == [3, 6, 2, 5, 1, 4])
        #expect(grid.applying(.rotate(.halfTurn), background: 0).pixels == [6, 5, 4, 3, 2, 1])
    }

    @Test func fourQuarterTurnsAreIdentity() {
        var g = grid
        for _ in 0..<4 { g = g.applying(.rotate(.clockwise), background: 0) }
        #expect(g == grid)
    }

    @Test func wholeFactorEnlargeCopiesPixels() {
        let big = grid.applying(.resize(width: 6, height: 4), background: 0)
        #expect(big[0, 0] == 1 && big[1, 1] == 1 && big[2, 0] == 2 && big[5, 3] == 6)
    }

    @Test func halvingAveragesBlocks() {
        let black = RGBA.black.packed, white = RGBA.white.packed
        let checker = PixelGrid(width: 2, height: 2, pixels: [black, white, white, black])
        let shrunk = checker.applying(.resize(width: 1, height: 1), background: 0)
        #expect(RGBA(packed: shrunk[0, 0]) == RGBA(128, 128, 128))
    }

    @Test func skewOffsetsMatchPaintsTable() {
        #expect(Skew.offset(100, degrees: 45) == 100)
        #expect(Skew.offset(100, degrees: -45) == 100)
        // tan 10° ≈ 0.1763: (100·10⁶ / 567128 + 5) / 10 = 18
        #expect(Skew.offset(100, degrees: 10) == 18)
        #expect(Skew.offset(100, degrees: 0) == 0)
    }

    @Test func positiveHorizontalSkewLeansTopRight() {
        let column = PixelGrid(width: 1, height: 3, pixels: [7, 8, 9])
        let skewed = column.applying(.skewHorizontal(degrees: 45), background: 0)
        #expect(skewed.width == 4)
        #expect(skewed[2, 0] == 7, "top row moves furthest")
        #expect(skewed[1, 1] == 8)
        #expect(skewed[0, 2] == 9, "bottom row stays put")
        #expect(skewed[0, 0] == 0, "uncovered area is background")
    }

    @Test func negativeHorizontalSkewLeansTopLeft() {
        let column = PixelGrid(width: 1, height: 3, pixels: [7, 8, 9])
        let skewed = column.applying(.skewHorizontal(degrees: -45), background: 0)
        #expect(skewed[1, 0] == 7)
        #expect(skewed[3, 2] == 9)
    }

    @Test func positiveVerticalSkewPushesLeftEdgeDown() {
        let row = PixelGrid(width: 3, height: 1, pixels: [7, 8, 9])
        let skewed = row.applying(.skewVertical(degrees: 45), background: 0)
        #expect(skewed.height == 4)
        #expect(skewed[0, 2] == 7)
        #expect(skewed[2, 0] == 9)
    }

    @Test func freeFormMaskRotatesWithPixels() throws {
        // Lower-left triangle in a 4×2 box.
        let mask = try #require(SelectionMask(
            polygon: [point(0, 0), point(0, 1), point(3, 1)],
            within: PixelRect(x: 0, y: 0, width: 10, height: 10)
        ))
        let rotated = mask.applying(.rotate(.clockwise))
        #expect(rotated.rect == PixelRect(x: 0, y: 0, width: 2, height: 4))
        #expect(rotated.contains(point(1, 0)) == mask.contains(point(0, 0)))
        #expect(rotated.contains(point(0, 3)) == mask.contains(point(3, 1)))
        #expect(!rotated.contains(point(1, 3)), "the empty corner moves too")
        #expect(rotated.outline?.count == mask.outline?.count)
    }

    @Test func selectionRotatesInPlace() {
        let bitmap = Bitmap(width: 10, height: 10)
        let blue = RGBA(63, 72, 204)
        bitmap[point(2, 2)] = blue // top-left of a 3×2 selection at (2, 2)
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 2, y: 2, width: 3, height: 2)))
        session.apply(.rotate(.clockwise), background: .white)
        #expect(session.mask.rect == PixelRect(x: 2, y: 2, width: 2, height: 3))
        #expect(bitmap[point(3, 2)] == blue, "top-left corner goes to top-right")
        #expect(bitmap[point(2, 2)] == .white)
        // The vacated column to the right is background now.
        #expect(bitmap[point(4, 2)] == .white)
        bitmap.restore(bitmap.snapshot(session.dirty, from: session.before))
        #expect(bitmap[point(2, 2)] == blue)
    }
}
