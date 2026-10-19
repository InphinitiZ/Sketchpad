import AppKit
import PaintCore

/// Paint's arrow-key movement (`InputProcessor`). The first press moves one step at once.
/// While arrows stay down, a 10 ms timer moves on: nothing for the first `minimumTime`, then a
/// step that grows linearly from `minimumDistance` to `maximumDistance` by `maximumTime`. These
/// are Paint's `Keyboard` settings, which default to 1, 5, 100 ms and 2000 ms (set in `CPBApp`'s
/// constructor). Shift doubles the timer's steps; with the scroll modifier held they scroll the
/// picture instead.
final class ArrowKeyMotion {
    struct Step: Equatable {
        var dx: Int
        var dy: Int
        var scrolls = false
    }

    static let interval: TimeInterval = 0.01
    static let minimumDistance = 1
    static let maximumDistance = 5
    /// In milliseconds, as Paint keeps them.
    static let minimumTime = 100
    static let maximumTime = 2000

    /// The arrows held down, in the order they were pressed.
    private(set) var held: [UInt16] = []
    /// Set by the first press, cleared once no arrow points anywhere.
    private(set) var isMoving = false
    private var start: TimeInterval = 0
    private var timer: Timer?
    private let onStep: (Step) -> Void

    init(onStep: @escaping (Step) -> Void) {
        self.onStep = onStep
    }

    deinit {
        timer?.invalidate()
    }

    static func direction(of keyCode: UInt16) -> (dx: Int, dy: Int)? {
        switch keyCode {
        case 123: (-1, 0)
        case 124: (1, 0)
        case 125: (0, 1)
        case 126: (0, -1)
        default: nil
        }
    }

    /// Paint's step for arrows held `elapsed` milliseconds (`InputProcessor::ProcessKeyboard`).
    static func distance(afterMilliseconds elapsed: Int) -> Int {
        let ramp = elapsed - minimumTime
        guard ramp >= 0 else { return 0 }
        let distance = (maximumDistance - minimumDistance) * ramp / (maximumTime - minimumTime) + minimumDistance
        return min(max(distance, minimumDistance), maximumDistance)
    }

    /// Returns `false` for keys other than the arrows. Repeats, and arrows pressed while
    /// already moving, are left to the timer.
    func keyDown(_ keyCode: UInt16, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let direction = Self.direction(of: keyCode) else { return false }
        if !held.contains(keyCode) { held.append(keyCode) }
        guard !isMoving else { return true }
        isMoving = true
        start = time
        onStep(Step(dx: direction.dx, dy: direction.dy))
        startTimer()
        return true
    }

    func keyUp(_ keyCode: UInt16) -> Bool {
        guard Self.direction(of: keyCode) != nil else { return false }
        held.removeAll { $0 == keyCode }
        if held.isEmpty { stop() }
        return true
    }

    /// One timer tick: the held arrows' combined direction at the current speed.
    func tick(at time: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        let direction = held.compactMap(Self.direction).reduce((dx: 0, dy: 0)) { ($0.dx + $1.dx, $0.dy + $1.dy) }
        if direction == (0, 0), isMoving {
            isMoving = false
            return
        }
        var distance = Self.distance(afterMilliseconds: Int(((time - start) * 1000).rounded(.down)))
        if modifiers.contains(.shift) { distance *= 2 }
        guard distance > 0, direction != (0, 0) else { return }
        onStep(Step(dx: direction.dx * distance, dy: direction.dy * distance, scrolls: modifiers.contains(.option)))
    }

    /// Lets go of everything, as when the canvas loses focus.
    func stop() {
        held.removeAll()
        isMoving = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.tick(at: ProcessInfo.processInfo.systemUptime, modifiers: NSEvent.modifierFlags)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// The mouse pointer, which Paint's keyboard drawing moves (`VirtualCursor`); tests use a
/// stand-in so they leave the real pointer alone.
struct Pointer {
    /// Where the pointer is, in screen coordinates.
    var location: () -> NSPoint
    /// Puts the pointer somewhere, in screen coordinates.
    var warp: (NSPoint) -> Void
    /// Whether the keys may move the pointer for this window (Paint: when it is in front).
    var isAvailable: (NSWindow) -> Bool

    static var system: Pointer {
        Pointer(
            location: { NSEvent.mouseLocation },
            warp: { point in
                // Quartz puts the origin at the top left of the main screen.
                let height = NSScreen.screens.first?.frame.height ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: point.x, y: height - point.y))
            },
            isAvailable: { $0.isKeyWindow }
        )
    }
}

/// Paint's keyboard drawing (`CImgWnd::OnKeyDown`, `VirtualCursor`): with nothing selected,
/// the arrows move the pointer over the visible part of the picture, and the space bar is the
/// mouse button, so every tool works from the keyboard.
extension CanvasView {
    /// Where the arrows may take the pointer: the visible part of the picture, less 2 screen
    /// points at the right and bottom, in canvas coordinates.
    var keyboardPointerArea: CGRect {
        let zoom = enclosingScrollView?.magnification ?? 1
        var area = visibleRect.intersection(bounds)
        guard !area.isNull else { return .null }
        area.size.width = max(0, area.width - 2 / zoom)
        area.size.height = max(0, area.height - 2 / zoom)
        return area
    }

    /// Routes one arrow-key step: to the handle chosen with Tab, the shape being edited or the
    /// selection when there is one (the tool's `OnDeltaMovement`), else to the pointer.
    func keyboardStep(_ step: ArrowKeyMotion.Step) {
        if step.scrolls {
            onKeyboardScroll?(CGFloat(step.dx), CGFloat(step.dy))
        } else if keyboardHandle != nil, activeShape != nil || selection != nil {
            moveKeyboardHandle(dx: step.dx, dy: step.dy)
        } else if activeShape != nil {
            moveActiveShape(dx: step.dx, dy: step.dy)
        } else if selection != nil {
            nudgeSelection(dx: step.dx, dy: step.dy)
        } else {
            moveKeyboardPointer(dx: step.dx, dy: step.dy)
        }
    }

    /// Moves the pointer by screen points, kept within `keyboardPointerArea`. A pointer
    /// left elsewhere first jumps back to where the keys last put it.
    func moveKeyboardPointer(dx: Int, dy: Int) {
        guard let window, pointer.isAvailable(window) else { return }
        let area = keyboardPointerArea
        guard !area.isEmpty else { return }
        let zoom = enclosingScrollView?.magnification ?? 1
        let here = pointerLocation(in: window)
        if !area.contains(here), hypot(here.x - keyboardPointer.x, here.y - keyboardPointer.y) > 0.5 / zoom {
            warpPointer(to: keyboardPointer, in: window)
            // Moving the pointer sends no event, so the tool's pointer is set here.
            ToolCursors.cursor(for: state, magnification: zoom).set()
            return
        }
        var next = CGPoint(x: here.x + CGFloat(dx) / zoom, y: here.y + CGFloat(dy) / zoom)
        next.x = next.x <= area.minX ? area.minX : min(next.x, area.maxX)
        next.y = next.y <= area.minY ? area.minY : min(next.y, area.maxY)
        warpPointer(to: next, in: window)
        keyboardPointer = next
        sendPointerEvent(isKeyboardButtonDown ? .leftMouseDragged : .mouseMoved, at: next, in: window)
    }

    /// The space bar goes down: the mouse button, pressed where the pointer is. A pointer off
    /// the visible picture first jumps back to where the keys left it.
    func pressKeyboardButton() {
        guard let window, !isKeyboardButtonDown else { return }
        var here = pointerLocation(in: window)
        if !visibleRect.intersection(bounds).contains(here) {
            here = keyboardPointer
            warpPointer(to: here, in: window)
        }
        keyboardPointer = here
        isKeyboardButtonDown = true
        sendPointerEvent(.leftMouseDown, at: here, in: window)
    }

    func releaseKeyboardButton() {
        guard isKeyboardButtonDown else { return }
        isKeyboardButtonDown = false
        guard let window else { return }
        sendPointerEvent(.leftMouseUp, at: pointerLocation(in: window), in: window)
    }

    /// Paint's Ctrl+Space with a selection: the selection is placed on the picture.
    func placeSelectionFromKeyboard() {
        commitSelection()
        announce(localized("Successfully placed on canvas"))
    }

    private func pointerLocation(in window: NSWindow) -> CGPoint {
        convert(window.convertPoint(fromScreen: pointer.location()), from: nil)
    }

    private func warpPointer(to point: CGPoint, in window: NSWindow) {
        pointer.warp(window.convertPoint(toScreen: convert(point, to: nil)))
    }

    /// Hands the tools the same events the mouse would.
    private func sendPointerEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil), modifierFlags: NSEvent.modifierFlags.subtracting(.control),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1
        ) else { return }
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: mouseMoved(with: event)
        }
    }

    /// What VoiceOver says about using the canvas from the keyboard (Paint's strings 59539 and
    /// 59540, with the Mac's keys).
    var keyboardHelp: String {
        selection != nil || activeShape != nil
            ? localized("Press Return to place it on the canvas. Press Esc at any time to cancel. Press the arrow keys to move. Press Tab to switch between control points in clockwise order; Shift+Tab switches in counter-clockwise order.")
            : localized("Press the arrow keys to move the pointer. Use the space bar to use the current tool. Hold Shift while moving to go faster. Hold Option while moving to scroll the canvas.")
    }
}
