import AppKit
import PaintCore
import UniformTypeIdentifiers

/// What a set of grab handles belongs to.
enum TrackerTarget {
    case canvas, selection, textBox, shape
}

/// A rectangle with grab handles, in canvas pixel coordinates.
struct Tracker: Equatable {
    let target: TrackerTarget
    let rect: CGRect
    let handles: [Handle]
}

/// The scroll view's document: Paint's workspace, with the canvas a few points in from the
/// top-left corner and an overlay on top for the grab handles, which reach past the canvas.
/// Inset and handles keep their on-screen size at every zoom.
final class CanvasWorkspaceView: NSView {
    /// Gap between the workspace's corner and the canvas, in screen points.
    static let inset: CGFloat = 5
    /// Room right of and below the canvas for its handles, in screen points.
    static let margin: CGFloat = 16

    let canvasView: CanvasView
    let handlesView: HandlesView

    init(canvasView: CanvasView) {
        self.canvasView = canvasView
        handlesView = HandlesView(canvasView: canvasView)
        super.init(frame: .zero)
        addSubview(canvasView)
        addSubview(handlesView)
        canvasView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(canvasFrameChanged), name: NSView.frameDidChangeNotification, object: canvasView
        )
        canvasView.onOverlayChange = { [weak self] in self?.handlesView.refresh() }
        registerForDraggedTypes([.fileURL])
        updateLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Screen points per workspace unit.
    var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// Places the canvas and sizes the workspace for the current zoom.
    func updateLayout() {
        let scale = magnification
        let inset = Self.inset / scale
        let origin = NSPoint(x: inset, y: inset)
        if canvasView.frame.origin != origin { canvasView.setFrameOrigin(origin) }
        let size = NSSize(
            width: inset + canvasView.frame.width + Self.margin / scale,
            height: inset + canvasView.frame.height + Self.margin / scale
        )
        if frame.size != size { setFrameSize(size) }
        handlesView.frame = bounds
        enclosingScrollView?.horizontalRulerView?.originOffset = inset
        enclosingScrollView?.verticalRulerView?.originOffset = inset
        // Handle sizes depend on the zoom, so always redraw here.
        handlesView.needsDisplay = true
        window?.invalidateCursorRects(for: handlesView)
    }

    @objc private func canvasFrameChanged() {
        updateLayout()
    }

    // MARK: - Dropping files

    /// Image files dropped on the window open, as Paint opens a picture dropped on it.
    private func imageURLs(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(in: sender).isEmpty ? [] : .copy
    }

    /// Like Paint, only the first of several dropped files opens.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = imageURLs(in: sender).first else { return false }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A soft shadow along the canvas's right and bottom edges, as in Paint's workspace.
        let unit = 1 / magnification
        let canvas = canvasView.frame
        NSColor(white: 0, alpha: 0.18).setFill()
        NSRect(x: canvas.maxX, y: canvas.minY + 3 * unit, width: 2 * unit, height: canvas.height).fill()
        NSRect(x: canvas.minX + 3 * unit, y: canvas.maxY, width: canvas.width - unit, height: 2 * unit).fill()
    }
}

/// Draws the grab handles of the canvas, the selection, the text box and a shape being edited,
/// and turns drags on them into resizing. Clicks anywhere else pass through to the canvas.
final class HandlesView: NSView {
    /// Handle side (Paint's 5×5 handle bitmap), in screen points.
    static let handleSize: CGFloat = 5
    /// Paint's `CTracker::HitTest` grabs a handle anywhere in a 31-point square around it,
    /// unless the press is more than half that inside the box, where it moves the box instead.
    static let grabZone: CGFloat = 31
    /// The text box's handles take only their own square (and a little), so clicks in the
    /// text keep placing the insertion point.
    static let textGrabTolerance: CGFloat = 3
    /// Paint's tracker sits 2 screen pixels outside the selection, text box or shape.
    static let trackerOutset: CGFloat = 2

    private let canvasView: CanvasView

    init(canvasView: CanvasView) {
        self.canvasView = canvasView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    private var shown: ([Tracker], PixelRect?, Handle?) = ([], nil, nil)

    /// Redraws if the handles moved since they were last drawn.
    func refresh() {
        guard window != nil else { return }
        let now = (canvasView.trackers, canvasView.canvasResizePreview, canvasView.keyboardHandle)
        guard now.0 != shown.0 || now.1 != shown.1 || now.2 != shown.2 else { return }
        shown = now
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The square of `handle` on `tracker`, in this view's coordinates.
    func frame(of handle: Handle, on tracker: Tracker) -> NSRect {
        var rect = convert(tracker.rect, from: canvasView)
        if tracker.target != .canvas {
            let outset = Self.trackerOutset / magnification
            rect = rect.insetBy(dx: -outset, dy: -outset)
        }
        let side = Self.handleSize / magnification
        let anchor = handle.anchor
        let center = NSPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
        // Canvas handles sit just outside the canvas; the others straddle their edge.
        let outward: CGFloat = tracker.target == .canvas ? side / 2 : 0
        return NSRect(
            x: center.x - side / 2 + (handle.movesRight ? outward : 0),
            y: center.y - side / 2 + (handle.movesBottom ? outward : 0),
            width: side, height: side
        )
    }

    /// Where a press grabs `handle`, in this view's coordinates.
    private func zone(of handle: Handle, on tracker: Tracker) -> NSRect {
        let square = frame(of: handle, on: tracker)
        let grow: CGFloat
        switch tracker.target {
        case .textBox: grow = Self.textGrabTolerance / magnification
        case .canvas, .selection, .shape: grow = (Self.grabZone - Self.handleSize) / 2 / magnification
        }
        return square.insetBy(dx: -grow, dy: -grow)
    }

    /// The box inside which a press moves the selection or shape rather than grabbing a handle.
    private func moveArea(of tracker: Tracker) -> NSRect? {
        switch tracker.target {
        case .selection, .shape:
            let outset = Self.trackerOutset / magnification, half = (Self.grabZone / 2).rounded(.down) / magnification
            return convert(tracker.rect, from: canvasView).insetBy(dx: -outset + half, dy: -outset + half)
        case .canvas, .textBox:
            return nil
        }
    }

    /// The handle under `point` (in this view's coordinates); later trackers win, so the
    /// selection's handles beat the canvas's where they overlap.
    func handle(at point: NSPoint) -> (Tracker, Handle)? {
        let canvasFrame = convert(canvasView.bounds, from: canvasView)
        for tracker in canvasView.trackers.reversed() {
            if let inside = moveArea(of: tracker), inside.contains(point) { return nil }
            for handle in tracker.handles where zone(of: handle, on: tracker).contains(point) {
                // The canvas's handles act only outside the picture, so drawing near its edge
                // never resizes it by accident.
                if tracker.target == .canvas, canvasFrame.contains(point) { continue }
                return (tracker, handle)
            }
        }
        return nil
    }

    /// The band around the text box, between the text and its handles, that drags the box.
    private func textBorder(contains point: NSPoint) -> Bool {
        guard let textBox = canvasView.textBox else { return false }
        let frame = convert(textBox.textView.frame, from: canvasView)
        let band = (Self.trackerOutset + 3) / magnification
        return frame.insetBy(dx: -band, dy: -band).contains(point) && !frame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canvasView.handleDragTarget == nil else { return self }
        let local = convert(point, from: superview)
        return handle(at: local) != nil || textBorder(contains: local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let unit = 1 / magnification
        if let preview = canvasView.canvasResizePreview {
            // The canvas outline follows the handle until the mouse is released.
            let outline = NSBezierPath(rect: convert(preview.cgRect, from: canvasView).insetBy(dx: unit / 2, dy: unit / 2))
            outline.lineWidth = unit
            outline.setLineDash([3 * unit, 3 * unit], count: 2, phase: 0)
            NSColor.black.setStroke()
            outline.stroke()
        }
        for tracker in canvasView.trackers {
            for handle in tracker.handles {
                let square = frame(of: handle, on: tracker).insetBy(dx: unit / 2, dy: unit / 2)
                // Paint's handle: a #555555 border around a window-colored center; the one
                // picked with Tab is filled with the highlight color.
                (handle == canvasView.keyboardHandle && tracker.target != .canvas ? NSColor.selectedContentBackgroundColor : NSColor.white).setFill()
                square.fill()
                let border = NSBezierPath(rect: square)
                border.lineWidth = unit
                NSColor(srgbRed: 0x55 / 255, green: 0x55 / 255, blue: 0x55 / 255, alpha: 1).setStroke()
                border.stroke()
            }
        }
    }

    override func resetCursorRects() {
        let canvasFrame = convert(canvasView.bounds, from: canvasView)
        for tracker in canvasView.trackers {
            if tracker.target == .textBox, let textBox = canvasView.textBox {
                // The border around the text drags the box.
                let frame = convert(textBox.textView.frame, from: canvasView)
                let band = (Self.trackerOutset + 3) / magnification
                for edge in [
                    NSRect(x: frame.minX - band, y: frame.minY - band, width: frame.width + 2 * band, height: band),
                    NSRect(x: frame.minX - band, y: frame.maxY, width: frame.width + 2 * band, height: band),
                    NSRect(x: frame.minX - band, y: frame.minY, width: band, height: frame.height),
                    NSRect(x: frame.maxX, y: frame.minY, width: band, height: frame.height),
                ] { addCursorRect(edge, cursor: Self.moveCursor) }
            }
            // Inside the selection or a shape the cursor shows it can be moved.
            if tracker.target == .selection || tracker.target == .shape {
                let outset = Self.trackerOutset / magnification
                addCursorRect(convert(tracker.rect, from: canvasView).insetBy(dx: -outset, dy: -outset), cursor: Self.moveCursor)
            }
            for handle in tracker.handles {
                var zone = zone(of: handle, on: tracker)
                if tracker.target == .canvas {
                    // Only the part outside the picture.
                    if handle.movesRight { zone = zone.intersection(NSRect(x: canvasFrame.maxX, y: zone.minY, width: zone.width, height: zone.height)) }
                    if handle == .bottom { zone = zone.intersection(NSRect(x: zone.minX, y: canvasFrame.maxY, width: zone.width, height: zone.height)) }
                }
                // A disjoint intersection is the infinite null rectangle, which AppKit rejects.
                guard !zone.isNull, !zone.isEmpty else { continue }
                addCursorRect(zone, cursor: Self.cursor(for: handle))
            }
        }
    }

    /// Four arrows: the selection or shape under the pointer can be dragged.
    static let moveCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
            NSColor.white.set()
            symbol?.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    static func cursor(for handle: Handle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .left: .left
            case .right: .right
            case .bottomLeft: .bottomLeft
            case .bottom: .bottom
            case .bottomRight: .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (tracker, handle) = handle(at: point) {
            canvasView.beginHandleDrag(tracker, handle, at: canvasPoint(event))
        } else if textBorder(contains: point) {
            canvasView.beginTextBoxMove(at: canvasPoint(event))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        canvasView.dragHandle(to: canvasPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        canvasView.endHandleDrag()
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        canvasView.convert(event.locationInWindow, from: nil)
    }
}
