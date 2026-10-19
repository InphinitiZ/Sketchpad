/// The grab handles Paint draws on a selection, a shape being edited, the text box and the
/// canvas edge, and how dragging one reshapes its rectangle.
public enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// The canvas has handles only where it can grow: the right edge, the bottom edge and the
    /// corner between them.
    public static let canvas: [Handle] = [.right, .bottom, .bottomRight]

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// Where the handle sits on `rect` as fractions of its width and height (0, ½ or 1).
    public var anchor: (x: Double, y: Double) {
        (movesLeft ? 0 : movesRight ? 1 : 0.5, movesTop ? 0 : movesBottom ? 1 : 0.5)
    }

    /// `rect` after dragging this handle by (`dx`, `dy`): the sides it holds move, the
    /// opposite sides stay put, and the result is never smaller than `minimum` on either side.
    public func resizing(_ rect: PixelRect, dx: Int, dy: Int, minimum: Int = 1) -> PixelRect {
        var left = rect.x, top = rect.y, right = rect.maxX, bottom = rect.maxY
        if movesLeft { left = min(left + dx, right - minimum) }
        if movesRight { right = max(right + dx, left + minimum) }
        if movesTop { top = min(top + dy, bottom - minimum) }
        if movesBottom { bottom = max(bottom + dy, top + minimum) }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
