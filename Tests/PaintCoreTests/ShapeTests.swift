import Testing
@testable import PaintCore

private let red = RGBA(237, 28, 36)
private let blue = RGBA(63, 72, 204)

private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

private func inked(_ bitmap: Bitmap) -> PixelRect {
    var rect = PixelRect.zero
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width where bitmap[point(x, y)] != .white {
            rect = rect.union(PixelRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return rect
}

@Suite struct ShapeTests {
    @Test(arguments: ShapeKind.allCases.filter(\.fitsBox))
    func boxShapesStayInsideTheirBox(kind: ShapeKind) {
        let bitmap = Bitmap(width: 120, height: 100)
        let box = PixelRect(enclosing: point(10, 10), point(89, 69))
        let drawn = bitmap.drawShape(kind, from: point(10, 10), to: point(89, 69), style: ShapeStyle(outline: .black, lineWidth: 5))
        let ink = inked(bitmap)
        #expect(!ink.isEmpty)
        #expect(ink.intersection(box) == ink, "\(kind) spills outside the dragged box \(box): \(ink)")
        #expect(drawn.intersection(ink) == ink, "reported area must cover what was drawn")
    }

    @Test(arguments: ShapeKind.allCases.filter(\.fitsBox))
    func filledShapesFillTheirMiddle(kind: ShapeKind) {
        let bitmap = Bitmap(width: 120, height: 120)
        bitmap.drawShape(kind, from: point(10, 10), to: point(109, 109), style: ShapeStyle(outline: nil, fill: blue))
        // Every shape covers some pixel near the middle of its box (callouts' bodies sit higher).
        let middle = (40...60).flatMap { y in (40...70).map { point($0, y) } }
        #expect(middle.contains { bitmap[$0] == blue }, "\(kind) has no fill near the middle")
    }

    @Test func noOutlineAndNoFillDrawsNothing() {
        let bitmap = Bitmap(width: 50, height: 50)
        bitmap.drawShape(.heart, from: point(5, 5), to: point(40, 40), style: ShapeStyle(outline: nil, fill: nil))
        #expect(inked(bitmap).isEmpty)
    }

    @Test func curvePassesThroughItsEnds() {
        let bitmap = Bitmap(width: 100, height: 100)
        bitmap.drawCurve(
            from: point(10, 50), to: point(90, 50), control1: point(30, 0), control2: point(70, 0),
            style: ShapeStyle(outline: red, antialiased: false)
        )
        #expect(bitmap[point(10, 50)] == red)
        #expect(bitmap[point(90, 50)] == red)
        #expect(bitmap[point(50, 50)] == .white, "the middle is bent upward")
        #expect(inked(bitmap).y < 30)
    }

    @Test func closedPolygonFillsOpenOneDoesNot() {
        let triangle = [point(10, 10), point(50, 10), point(10, 50)]
        let style = ShapeStyle(outline: .black, fill: blue, antialiased: false)

        let open = Bitmap(width: 60, height: 60)
        open.drawPolygon(triangle, closed: false, style: style)
        #expect(open[point(20, 20)] == .white)

        let closed = Bitmap(width: 60, height: 60)
        closed.drawPolygon(triangle, closed: true, style: style)
        #expect(closed[point(20, 20)] == blue)
        #expect(closed[point(10, 30)] == .black, "closing edge is drawn")
    }

    @Test func thinBoxIsAllOutline() {
        let bitmap = Bitmap(width: 30, height: 30)
        bitmap.drawShape(.rectangle, from: point(5, 5), to: point(20, 6), style: ShapeStyle(outline: red, lineWidth: 8, antialiased: false))
        #expect(bitmap[point(10, 5)] == red && bitmap[point(10, 6)] == red)
        #expect(bitmap[point(10, 7)] == .white)
    }
}
