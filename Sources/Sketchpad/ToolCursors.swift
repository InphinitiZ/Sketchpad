import AppKit
import PaintCore

/// The pointer over the canvas, which shows the current tool as Paint's does: a glyph for the
/// pencil, fill, picker and magnifier, the eraser's square filled with Color 2, the brush's
/// footprint, an I-beam for text and a crosshair for selecting and shapes. Footprints are
/// drawn at the current zoom.
enum ToolCursors {
    /// Footprints larger than this many points on screen fall back to a crosshair.
    static let largestFootprint: CGFloat = 128

    static func cursor(for state: EditorState, magnification: CGFloat) -> NSCursor {
        switch state.tool {
        case .select, .freeFormSelect, .shape:
            return .crosshair
        case .text:
            return .iBeam
        case .pencil:
            return glyph("pencil", hotSpot: NSPoint(x: 2, y: 21))
        case .fill:
            return bucket
        case .picker:
            return glyph("eyedropper", hotSpot: NSPoint(x: 2, y: 21))
        case .magnifier:
            return glyph("magnifyingglass", hotSpot: NSPoint(x: 9, y: 9))
        case .eraser:
            let side = CGFloat(state.size) * magnification
            return footprint(size: NSSize(width: side, height: side)) { rect in
                state.secondary.nsColor.setFill()
                rect.fill()
                NSColor.black.setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        case .brush:
            let width: CGFloat
            switch state.brushKind {
            case .airbrush: width = CGFloat(Airbrush.diameter(forSize: state.size))
            case let kind where kind.medium != nil: width = CGFloat(kind.medium!.strokeWidth(size: state.size, pressure: nil))
            default: width = CGFloat(state.size)
            }
            let side = width * magnification
            guard side >= 4 else { return .crosshair }
            return footprint(size: NSSize(width: side, height: side)) { rect in
                let outline: NSBezierPath
                switch state.brushKind {
                case .calligraphy45:
                    outline = NSBezierPath()
                    outline.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                    outline.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                case .calligraphy135:
                    outline = NSBezierPath()
                    outline.move(to: NSPoint(x: rect.minX, y: rect.minY))
                    outline.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                default:
                    outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    if state.brushKind == .airbrush { outline.setLineDash([2, 2], count: 2, phase: 0) }
                }
                // Light under dark, so the outline shows on any color.
                outline.lineWidth = 2
                NSColor.white.setStroke()
                outline.stroke()
                outline.lineWidth = 1
                NSColor.black.setStroke()
                outline.stroke()
            }
        }
    }

    /// A shape drawn at its on-screen size, with the hot spot in its middle.
    private static func footprint(size: NSSize, draw: @escaping (NSRect) -> Void) -> NSCursor {
        guard size.width <= largestFootprint else { return .crosshair }
        let side = max(size.width, size.height).rounded(.up) + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            draw(NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    private static var glyphs: [String: NSCursor] = [:]

    /// An SF Symbol with a white halo, its hot spot at the tool's working end.
    private static func glyph(_ name: String, hotSpot: NSPoint) -> NSCursor {
        if let cached = glyphs[name] { return cached }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            guard let symbol else { return false }
            let glyph = NSRect(x: 2, y: 2, width: 20, height: 20)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                tinted(symbol, .white).draw(in: glyph.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)))
            }
            tinted(symbol, .black).draw(in: glyph)
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: hotSpot)
        glyphs[name] = cursor
        return cursor
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static let bucket: NSCursor = {
        let icon = RibbonIcons.fillBucket(size: 22)
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            icon.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        // The pouring drop is the working end, at the bottom right.
        return NSCursor(image: image, hotSpot: NSPoint(x: 20, y: 20))
    }()
}
