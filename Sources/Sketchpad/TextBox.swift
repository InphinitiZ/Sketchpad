import AppKit
import PaintCore

/// The text tool's box. While open it is a live text view on top of the canvas; committing
/// draws its laid-out text into the bitmap, after which it can no longer be edited (as in Paint).
final class TextBox: NSObject, NSTextViewDelegate {
    let textView: NSTextView
    /// Typing gets its own undo stack, so it never mixes with the document's pixel edits.
    private let typingUndoManager = UndoManager()

    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?

    init(frame: NSRect, style: TextStyle, color: RGBA, background: RGBA) {
        textView = NSTextView(frame: frame)
        super.init()
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = frame.size
        textView.maxSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        apply(style: style, color: color, background: background)
    }

    var isEmpty: Bool { textView.string.isEmpty }

    /// Restyles the whole box. Paint's text box applies one style to all of its text.
    func apply(style: TextStyle, color: RGBA, background: RGBA) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: color.nsColor,
        ]
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        textView.typingAttributes = attributes
        if let storage = textView.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.drawsBackground = style.opaque
        textView.backgroundColor = background.nsColor
        textView.insertionPointColor = color.nsColor
        onChange?()
    }

    /// Draws the text into `bitmap` at the box's position and returns the area it covers.
    @discardableResult
    func render(into bitmap: Bitmap, opaque: Bool, background: RGBA) -> PixelRect {
        let frame = textView.frame
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }

        let context = bitmap.context
        context.saveGState()
        defer { context.restoreGState() }
        // Grayscale antialiasing: subpixel smoothing would bake colored fringes into the pixels.
        context.setShouldSmoothFonts(false)
        if opaque {
            context.setFillColor(background.cgColor)
            context.fill(frame)
        }

        NSGraphicsContext.saveGraphicsState()
        // The bitmap's context is already flipped to a top-left origin.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = NSPoint(x: frame.minX + textView.textContainerOrigin.x, y: frame.minY + textView.textContainerOrigin.y)
        layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: container), at: origin)
        NSGraphicsContext.restoreGraphicsState()

        return PixelRect(
            x: Int(frame.minX.rounded(.down)),
            y: Int(frame.minY.rounded(.down)),
            width: Int(frame.width.rounded(.up)) + 1,
            height: Int(frame.height.rounded(.up)) + 1
        ).intersection(bitmap.bounds)
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        typingUndoManager
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel?()
        return true
    }
}
