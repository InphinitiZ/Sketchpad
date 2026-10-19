import Testing
import UniformTypeIdentifiers
@testable import PaintCore

private let red = RGBA(237, 28, 36)

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

@Suite struct RasterTests {
    @Test func lineIncludesBothEndpoints() {
        var points: [PixelPoint] = []
        Raster.linePoints(from: point(0, 0), to: point(5, 2)) { points.append($0) }
        #expect(points.first == point(0, 0))
        #expect(points.last == point(5, 2))
        #expect(points.count == 6)
    }

    @Test func singlePixelPencilTouchesOnlyThatPixel() {
        let bitmap = Bitmap(width: 4, height: 4)
        let rect = bitmap.stampSquare(at: point(2, 1), size: 1, color: .black)
        #expect(rect == PixelRect(x: 2, y: 1, width: 1, height: 1))
        #expect(bitmap[point(2, 1)] == .black)
        #expect(bitmap[point(1, 1)] == .white)
    }

    @Test func floodFillStopsAtBorder() {
        let bitmap = Bitmap(width: 10, height: 10)
        bitmap.drawShape(.rectangle, from: point(2, 2), to: point(7, 7), style: ShapeStyle(outline: .black, antialiased: false))
        let filled = bitmap.floodFill(at: point(4, 4), with: red)
        #expect(filled == PixelRect(x: 3, y: 3, width: 4, height: 4))
        #expect(bitmap[point(4, 4)] == red)
        #expect(bitmap[point(2, 2)] == .black)
        #expect(bitmap[point(0, 0)] == .white)
    }

    @Test func floodFillWithSameColorIsNoOp() {
        let bitmap = Bitmap(width: 3, height: 3)
        #expect(bitmap.floodFill(at: point(1, 1), with: .white).isEmpty)
    }

    @Test func floodFillIsFourConnected() {
        // Two white cells touching only at a corner must not leak into each other.
        let bitmap = Bitmap(width: 2, height: 2, fill: .black)
        bitmap[point(0, 0)] = .white
        bitmap[point(1, 1)] = .white
        bitmap.floodFill(at: point(0, 0), with: red)
        #expect(bitmap[point(1, 1)] == .white)
    }

    @Test func shiftConstraints() {
        #expect(Constraint.snap45(from: point(0, 0), to: point(10, 2)) == point(10, 0))
        #expect(Constraint.snap45(from: point(0, 0), to: point(1, 9)) == point(0, 9))
        #expect(Constraint.snap45(from: point(0, 0), to: point(-7, 6)) == point(-7, 7))
        #expect(Constraint.square(from: point(5, 5), to: point(8, 1)) == point(9, 1))
    }
}

@Suite struct BitmapTests {
    @Test func coreGraphicsUsesTopLeftOrigin() {
        let bitmap = Bitmap(width: 5, height: 5)
        bitmap.drawShape(.line, from: point(0, 0), to: point(4, 0), style: ShapeStyle(outline: .black, antialiased: false))
        #expect(bitmap[point(2, 0)] == .black)
        #expect(bitmap[point(2, 4)] == .white)
    }

    @Test func hardEdgedRectangleOutlineIsExact() {
        let bitmap = Bitmap(width: 8, height: 8)
        bitmap.drawShape(.rectangle, from: point(1, 1), to: point(6, 5), style: ShapeStyle(outline: red, antialiased: false))
        #expect(bitmap[point(1, 1)] == red)
        #expect(bitmap[point(6, 5)] == red)
        #expect(bitmap[point(3, 3)] == .white)
        #expect(bitmap[point(7, 7)] == .white)
    }

    @Test func snapshotRestoresEdit() {
        let bitmap = Bitmap(width: 6, height: 6)
        let before = bitmap.copyPixels()
        let rect = bitmap.floodFill(at: point(0, 0), with: red)
        let snapshot = bitmap.snapshot(rect, from: before)
        bitmap.restore(snapshot)
        #expect(bitmap[point(3, 3)] == .white)
    }

    @Test func pngRoundTripKeepsPixelsAndOrientation() throws {
        let bitmap = Bitmap(width: 3, height: 2)
        bitmap[point(0, 0)] = red
        let data = try ImageCodec.encode(try #require(bitmap.makeImage()), as: .png)
        let decoded = Bitmap(image: try #require(ImageCodec.decode(data)))
        #expect(decoded.width == 3 && decoded.height == 2)
        #expect(decoded[point(0, 0)] == red)
        #expect(decoded[point(0, 1)] == .white)
    }

    @Test(arguments: [UTType.jpeg, UTType.bmp])
    func lossyAndBitmapFormatsEncode(type: UTType) throws {
        let bitmap = Bitmap(width: 4, height: 4)
        let data = try ImageCodec.encode(try #require(bitmap.makeImage()), as: type)
        #expect(ImageCodec.decode(data)?.width == 4)
    }
}
