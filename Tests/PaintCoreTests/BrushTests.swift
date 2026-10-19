import Testing
@testable import PaintCore

private let blue = RGBA(63, 72, 204)

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// Deterministic generator for the airbrush (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct BrushTests {
    @Test func circleMasksMatchPaintsRule() {
        // 1: just the center. 2: the full 2×2 block. 3: a plus sign (corners are √2 > 1.25 away).
        #expect(Bitmap.circleMask(diameter: 1) == [true])
        #expect(Bitmap.circleMask(diameter: 2) == [true, true, true, true])
        #expect(Bitmap.circleMask(diameter: 3) == [false, true, false, true, true, true, false, true, false])
        // 8: corners out, edge midpoints in.
        let eight = Bitmap.circleMask(diameter: 8)
        #expect(!eight[0] && eight[3] && eight[8 * 3])
    }

    @Test func roundBrushIsACapsule() {
        let bitmap = Bitmap(width: 40, height: 20)
        bitmap.drawRoundBrushLine(from: point(10, 10), to: point(30, 10), diameter: 5, color: blue)
        #expect(bitmap[point(20, 8)] == blue && bitmap[point(20, 12)] == blue)
        #expect(bitmap[point(20, 7)] == .white)
        #expect(bitmap[point(8, 10)] == blue, "round end cap")
        #expect(bitmap[point(8, 8)] == .white, "cap corners are cut")
    }

    @Test(arguments: [BrushKind.calligraphy45, .calligraphy135])
    func calligraphyHasNoHolesAcrossTheNib(kind: BrushKind) {
        let bitmap = Bitmap(width: 60, height: 60)
        // Drag across the nib's slant, where stamping alone would leave a checkerboard.
        let end = kind == .calligraphy45 ? point(40, 40) : point(40, 20)
        bitmap.drawCalligraphyLine(from: point(20, kind == .calligraphy45 ? 20 : 40), to: end, width: 8, kind: kind, color: blue)
        let mid = PixelPoint(x: 30, y: 30)
        for dx in -2...2 { #expect(bitmap[PixelPoint(x: mid.x + dx, y: mid.y)] == blue) }
    }

    @Test func calligraphyStrokeIsThinAlongTheNib() {
        let bitmap = Bitmap(width: 60, height: 60)
        // Moving along "/" with a "/" nib draws a 1-pixel-wide diagonal.
        bitmap.drawCalligraphyLine(from: point(20, 40), to: point(40, 20), width: 8, kind: .calligraphy45, color: blue)
        #expect(bitmap[point(30, 30)] == blue)
        #expect(bitmap[point(30, 29)] == .white && bitmap[point(31, 31)] == .white)
    }

    @Test func airbrushPlacesTenDotsInsideItsCircle() {
        let bitmap = Bitmap(width: 50, height: 50)
        var generator = SeededGenerator(state: 42)
        bitmap.spray(at: point(25, 25), size: 16, color: blue, using: &generator)
        var dots: [PixelPoint] = []
        for y in 0..<50 { for x in 0..<50 where bitmap[point(x, y)] == blue { dots.append(point(x, y)) } }
        #expect((1...10).contains(dots.count), "10 placements, some may coincide")
        for dot in dots {
            let dx = dot.x - 25, dy = dot.y - 25
            #expect(dx * dx + dy * dy <= 64)
        }
    }

    @Test func airbrushDiameterIsEvenAndAtLeastFour() {
        #expect(Airbrush.diameter(forSize: 1) == 4)
        #expect(Airbrush.diameter(forSize: 5) == 6)
        #expect(Airbrush.diameter(forSize: 8) == 8)
    }
}
