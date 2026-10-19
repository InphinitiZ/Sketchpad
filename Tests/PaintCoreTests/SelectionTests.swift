import Testing
@testable import PaintCore

private let blue = RGBA(63, 72, 204)

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

@Suite struct SelectionMaskTests {
    @Test func polygonCoversInteriorAndOutline() throws {
        let mask = try #require(SelectionMask(
            polygon: [point(0, 0), point(8, 0), point(8, 8), point(0, 8)],
            within: PixelRect(x: 0, y: 0, width: 20, height: 20)
        ))
        #expect(mask.rect == PixelRect(x: 0, y: 0, width: 9, height: 9))
        #expect(mask.contains(point(4, 4)))
        #expect(mask.contains(point(8, 8)))
        #expect(!mask.contains(point(9, 4)))
        #expect(!mask.isRectangular)
    }

    @Test func triangleExcludesOppositeCorner() throws {
        let mask = try #require(SelectionMask(
            polygon: [point(0, 0), point(10, 0), point(0, 10)],
            within: PixelRect(x: 0, y: 0, width: 20, height: 20)
        ))
        #expect(mask.contains(point(2, 2)))
        #expect(!mask.contains(point(9, 9)))
    }

    @Test func polygonIsClippedToCanvas() throws {
        let mask = try #require(SelectionMask(
            polygon: [point(-5, -5), point(5, -5), point(5, 5), point(-5, 5)],
            within: PixelRect(x: 0, y: 0, width: 10, height: 10)
        ))
        #expect(mask.rect == PixelRect(x: 0, y: 0, width: 6, height: 6))
    }

    @Test func tooFewPointsIsNoSelection() {
        #expect(SelectionMask(polygon: [point(0, 0), point(3, 3)], within: PixelRect(x: 0, y: 0, width: 5, height: 5)) == nil)
    }
}

@Suite struct SelectionSessionTests {
    /// A 10×10 white canvas with a 2×2 blue square at (1, 1).
    private func canvas() -> Bitmap {
        let bitmap = Bitmap(width: 10, height: 10)
        bitmap.fill(SelectionMask(rect: PixelRect(x: 1, y: 1, width: 2, height: 2)), with: blue)
        return bitmap
    }

    @Test func liftAndMoveLeavesBackgroundBehind() {
        let bitmap = canvas()
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 1, y: 1, width: 2, height: 2)))
        session.lift(background: .white, transparent: nil)
        session.move(dx: 5, dy: 0)
        #expect(bitmap[point(1, 1)] == .white)
        #expect(bitmap[point(6, 1)] == blue)
        #expect(session.dirty == PixelRect(x: 1, y: 1, width: 7, height: 2))
    }

    @Test func movingTwiceRestoresIntermediatePosition() {
        let bitmap = canvas()
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 1, y: 1, width: 2, height: 2)))
        session.lift(background: .white, transparent: nil)
        session.move(dx: 3, dy: 0)
        session.move(dx: 3, dy: 0)
        #expect(bitmap[point(4, 1)] == .white)
        #expect(bitmap[point(7, 1)] == blue)
    }

    @Test func transparentSelectionSkipsBackgroundColor() {
        let bitmap = canvas()
        bitmap[point(5, 1)] = .black
        // Select blue square plus white pixels around it, drag it over the black pixel.
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 0, y: 0, width: 4, height: 4)))
        session.lift(background: .white, transparent: .white)
        session.move(dx: 5, dy: 0)
        #expect(bitmap[point(5, 1)] == .black, "white pixels in the selection are see-through")
        #expect(bitmap[point(6, 1)] == blue)
    }

    @Test func undoSnapshotRestoresOriginal() {
        let bitmap = canvas()
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 1, y: 1, width: 2, height: 2)))
        session.lift(background: .white, transparent: nil)
        session.move(dx: 4, dy: 4)
        bitmap.restore(bitmap.snapshot(session.dirty, from: session.before))
        #expect(bitmap[point(1, 1)] == blue)
        #expect(bitmap[point(5, 5)] == .white)
    }

    @Test func eraseDropsLiftedPixels() {
        let bitmap = canvas()
        let session = SelectionSession(bitmap: bitmap, mask: SelectionMask(rect: PixelRect(x: 1, y: 1, width: 2, height: 2)))
        session.lift(background: .white, transparent: nil)
        session.move(dx: 2, dy: 2)
        session.erase(background: .white)
        #expect(bitmap[point(3, 3)] == .white)
        #expect(bitmap[point(1, 1)] == .white)
    }

    @Test func pasteFloatsAndCanBeMoved() {
        let bitmap = Bitmap(width: 8, height: 8)
        let session = SelectionSession(
            bitmap: bitmap, pasting: [UInt32](repeating: blue.packed, count: 4),
            width: 2, height: 2, at: point(0, 0), transparent: nil
        )
        #expect(session.isFloating)
        #expect(bitmap[point(0, 0)] == blue)
        session.move(dx: 6, dy: 6)
        #expect(bitmap[point(0, 0)] == .white)
        #expect(bitmap[point(7, 7)] == blue)
    }

    @Test func freeFormCopyFillsOutsideWithBackground() throws {
        let bitmap = Bitmap(width: 10, height: 10, fill: blue)
        let mask = try #require(SelectionMask(polygon: [point(0, 0), point(6, 0), point(0, 6)], within: bitmap.bounds))
        let pixels = SelectionSession(bitmap: bitmap, mask: mask).selectedPixels(outside: .white)
        #expect(RGBA(packed: pixels[0]) == blue)
        #expect(RGBA(packed: pixels[pixels.count - 1]) == .white)
    }
}
