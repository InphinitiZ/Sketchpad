import CoreGraphics
import Testing
@testable import PaintCore

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

/// Paints a straight stroke of `medium` across a white 120×60 canvas.
private func stroke(
    _ medium: Medium, color: RGBA = .black, from a: CGPoint = CGPoint(x: 10, y: 30), to b: CGPoint = CGPoint(x: 110, y: 30),
    radius: Double = 10, on bitmap: Bitmap = Bitmap(width: 120, height: 60)
) -> Bitmap {
    let layer = MediumLayer(medium: medium, color: color, limit: bitmap.bounds, seed: 7)
    bitmap.composite(layer, in: layer.addSegment(from: a, width: 2 * radius, to: b, width: 2 * radius))
    return bitmap
}

private func luminance(_ c: RGBA) -> Int { (Int(c.r) + Int(c.g) + Int(c.b)) / 3 }

@Suite struct MediaTests {
    @Test func markerBuildsUpWhereAStrokeCrossesItselfButNotAtItsJoints() {
        let layer = MediumLayer(medium: .marker, color: .black, limit: PixelRect(x: 0, y: 0, width: 120, height: 60))
        // A bent stroke: right, then down, then back left across its first part.
        layer.addSegment(from: CGPoint(x: 10, y: 20), width: 8, to: CGPoint(x: 60, y: 20), width: 8)
        layer.addSegment(from: CGPoint(x: 60, y: 20), width: 8, to: CGPoint(x: 60, y: 50), width: 8)
        layer.addSegment(from: CGPoint(x: 60, y: 50), width: 8, to: CGPoint(x: 30, y: 50), width: 8)
        layer.addSegment(from: CGPoint(x: 30, y: 50), width: 8, to: CGPoint(x: 30, y: 5), width: 8)
        #expect(layer.opacity(atX: 45, y: 20) == 0.5, "half-transparent")
        #expect(layer.opacity(atX: 60, y: 20) == 0.5, "the joint is no darker")
        #expect(layer.opacity(atX: 30, y: 20) == 0.75, "where it crosses itself it builds up")

        let bitmap = Bitmap(width: 120, height: 60)
        _ = stroke(.marker, from: CGPoint(x: 10, y: 30), to: CGPoint(x: 100, y: 30), radius: 6, on: bitmap)
        let once = luminance(bitmap[point(80, 30)])
        _ = stroke(.marker, from: CGPoint(x: 80, y: 5), to: CGPoint(x: 80, y: 55), radius: 6, on: bitmap)
        #expect(luminance(bitmap[point(80, 30)]) < once, "a second stroke darkens too")
    }

    @Test func closedOutlinesJoinUpWithoutACrossing() {
        let layer = MediumLayer(medium: .marker, color: .black, limit: PixelRect(x: 0, y: 0, width: 60, height: 60))
        let corners = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 50), CGPoint(x: 10, y: 50), CGPoint(x: 10, y: 10)]
        layer.addPolyline(corners, width: 6)
        #expect(layer.opacity(atX: 10, y: 10) == 0.5)
        #expect(layer.opacity(atX: 50, y: 50) == 0.5)
    }

    @Test func pressureFollowsPaintsWidthRule() {
        #expect(Medium.oil.strokeWidth(size: 30, pressure: 1) == 40)
        #expect(Medium.watercolor.strokeWidth(size: 30, pressure: 0) == 20)
        #expect(Medium.crayon.strokeWidth(size: 16, pressure: 1) == 21)
        #expect(Medium.marker.strokeWidth(size: 16, pressure: 1) == 16, "marker ignores pressure")
        #expect(Medium.naturalPencil.strokeWidth(size: 4, pressure: 0) == 4)
        #expect(Medium.oil.strokeWidth(size: 30, pressure: nil) == 30, "a mouse has no pressure")
        #expect(Medium.oil.strokeWidth(size: 8, pressure: 0) == 1, "never thinner than a pixel")
    }

    @Test func textureOnlyChangesOpacityNeverTheColor() {
        let red = RGBA(200, 40, 40)
        for medium in Medium.allCases {
            let bitmap = stroke(medium, color: red)
            for x in stride(from: 15, to: 105, by: 7) {
                for y in 20..<41 {
                    let c = bitmap[point(x, y)]
                    // Every pixel lies between white and the color: the same share of each channel.
                    let share = Double(255 - Int(c.r)) / 55
                    #expect(abs(Double(255 - Int(c.g)) / 215 - share) < 0.02, "\(medium) at \(x), \(y): \(c)")
                    #expect(c.g == c.b)
                }
            }
        }
    }

    @Test func crayonSkipsTheHollowsOfThePaper() {
        let bitmap = stroke(.crayon)
        var inked = 0, bare = 0
        for x in 30..<90 {
            for y in 25..<35 {
                let l = luminance(bitmap[point(x, y)])
                if l < 64 { inked += 1 }
                if l > 192 { bare += 1 }
            }
        }
        #expect(inked > 120 && bare > 60, "both full wax and paper show (\(inked) inked, \(bare) bare of 600)")
    }

    @Test func texturesStayFixedToTheCanvas() {
        for medium in Medium.allCases {
            #expect(stroke(medium).copyPixels() == stroke(medium).copyPixels(), "\(medium)")
        }
    }

    @Test func naturalPencilIsLighterThanItsColor() {
        let bitmap = stroke(.naturalPencil, radius: 3)
        let values = (20..<100).map { luminance(bitmap[point($0, 30)]) }
        #expect(values.allSatisfy { $0 > 40 }, "never solid black")
        #expect(values.contains { $0 < 200 }, "but clearly marked")
    }

    @Test func watercolorPoolsAtTheRim() {
        let bitmap = stroke(.watercolor, color: RGBA(0, 0, 255))
        // Average across x to smooth the mottling.
        func blueness(_ y: Int) -> Int { (30..<90).map { 255 - Int(bitmap[point($0, y)].r) }.reduce(0, +) / 60 }
        #expect(blueness(22) > blueness(30) + 20, "rim \(blueness(22)) vs center \(blueness(30))")
        #expect(blueness(30) > 30, "the middle is still tinted")
    }

    @Test func oilStreaksRunAlongTheStroke() {
        let bitmap = stroke(.oil)
        func gray(_ x: Int, _ y: Int) -> Int { Int(bitmap[point(x, y)].r) }
        let across = Set((22..<39).map { gray(60, $0) })
        #expect(across.count >= 3, "bristles differ across the stroke")
        // Along a bristle the shade drifts only slowly.
        for y in 24..<37 {
            #expect(abs(gray(50, y) - gray(52, y)) <= 6, "row \(y)")
        }
    }

    @Test func pressureNarrowsTheStroke() {
        let bitmap = Bitmap(width: 120, height: 60)
        let layer = MediumLayer(medium: .marker, color: .black, limit: bitmap.bounds)
        bitmap.composite(layer, in: layer.addSegment(from: CGPoint(x: 10, y: 30), width: 4, to: CGPoint(x: 110, y: 30), width: 24))
        #expect(bitmap[point(15, 36)] == .white)
        #expect(bitmap[point(105, 36)] != .white)
    }

    @Test func compositingOverTheOriginalReplacesThePreviousPass() {
        let bitmap = Bitmap(width: 120, height: 60)
        let before = bitmap.copyPixels()
        let layer = MediumLayer(medium: .marker, color: .black, limit: bitmap.bounds)
        let first = layer.addSegment(from: CGPoint(x: 10, y: 30), width: 12, to: CGPoint(x: 60, y: 30), width: 12)
        bitmap.composite(layer, in: first, over: before)
        let once = bitmap[point(30, 30)]
        // Recompositing the same area again must not darken it.
        let second = layer.addSegment(from: CGPoint(x: 60, y: 30), width: 12, to: CGPoint(x: 100, y: 30), width: 12)
        bitmap.composite(layer, in: first.union(second), over: before)
        #expect(bitmap[point(30, 30)] == once)
    }

    @Test func texturedShapesStayInTheirBox() {
        let box = PixelRect(x: 20, y: 10, width: 60, height: 40)
        for medium in Medium.allCases {
            let bitmap = Bitmap(width: 120, height: 60)
            let style = ShapeStyle(outline: .black, fill: RGBA(0, 162, 232), lineWidth: 5, outlineMedium: medium, fillMedium: medium)
            bitmap.drawShape(.rectangle, from: point(box.x, box.y), to: point(box.maxX - 1, box.maxY - 1), style: style)
            for y in 0..<60 {
                for x in 0..<120 where !box.contains(point(x, y)) {
                    #expect(bitmap[point(x, y)] == .white, "\(medium) at \(x), \(y)")
                }
            }
            let middle = (25..<35).flatMap { y in (45..<55).map { bitmap[point($0, y)] } }
            #expect(middle.filter { $0 != .white }.count > 40, "\(medium) fills the middle")
            #expect(bitmap[point(22, 30)] != bitmap[point(50, 30)], "\(medium) outline differs from fill")
        }
    }

    @Test func thinAndMarkerOutlinesAreSolid() {
        func draw(_ medium: Medium?, width: Int) -> [UInt32] {
            let bitmap = Bitmap(width: 80, height: 60)
            bitmap.drawShape(.oval, from: point(10, 10), to: point(69, 49), style: ShapeStyle(outline: .black, lineWidth: width, outlineMedium: medium))
            return bitmap.copyPixels()
        }
        #expect(draw(.crayon, width: 3) == draw(nil, width: 3), "under 4 px")
        #expect(draw(.crayon, width: 5) != draw(nil, width: 5))
        #expect(draw(.marker, width: 8) == draw(nil, width: 8))
    }

    @Test func pathsFlattenIntoPolylines() {
        let square = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        let runs = square.polylines()
        #expect(runs.count == 1 && runs[0].count == 5 && runs[0].first == runs[0].last)

        let curve = CGMutablePath()
        curve.move(to: .zero)
        curve.addCurve(to: CGPoint(x: 90, y: 0), control1: CGPoint(x: 30, y: 60), control2: CGPoint(x: 60, y: 60))
        let points = curve.polylines()[0]
        #expect(points.count > 20)
        #expect(points.last == CGPoint(x: 90, y: 0))
        #expect(points.map(\.y).max()! > 40, "follows the bend")
    }
}
