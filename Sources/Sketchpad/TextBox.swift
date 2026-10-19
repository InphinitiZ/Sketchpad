import AppKit
import PaintCore

/// The text tool's box. While open it is a live rich-text view on top of the canvas; committing
/// draws its laid-out text into the bitmap, after which it can no longer be edited (as in Paint).
///
/// Like Paint's RichEdit box, font, size, bold, italic, underline, strikethrough and color
/// apply to the selected characters (or to what is typed next when nothing is selected), while
/// the opaque background fills the whole box.
final class TextBox: NSObject, NSTextViewDelegate {
    let textView: NSTextView
    /// Typing gets its own undo stack, so it never mixes with the document's pixel edits.
    private let typingUndoManager = UndoManager()
    /// The formatting last applied or read from the selection; changes are applied as
    /// differences from it, so other characters keep their own formatting.
    private(set) var style: TextStyle
    private var color: RGBA
    /// How far down the box may grow: Paint stops it at the bottom of the canvas.
    var maxBottom: CGFloat

    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?
    /// Reports the formatting where the insertion point or selection is, for the ribbon.
    var onSelectionStyle: ((TextStyle) -> Void)?

    init(frame: NSRect, style: TextStyle, color: RGBA, background: RGBA, maxBottom: CGFloat = .greatestFiniteMagnitude) {
        textView = NSTextView(frame: frame)
        self.style = style
        self.color = color
        self.maxBottom = maxBottom
        super.init()
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = Self.attributes(style, color)
        setFrame(frame)
        applyBackground(style: style, background: background)
    }

    var isEmpty: Bool { textView.string.isEmpty }

    /// Paint's smallest box for a click without a drag: room for about 20 characters and a line.
    static func minimumSize(for style: TextStyle) -> NSSize {
        let font = style.font
        let average = ("x" as NSString).size(withAttributes: [.font: font]).width
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return NSSize(width: (20 * average + 10).rounded(.up), height: (line + 10).rounded(.up))
    }

    /// Moves or resizes the box (its handles), keeping room for at least one line.
    func setFrame(_ frame: NSRect) {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: style.font)
        var frame = frame
        frame.size.width = max(frame.width, 8)
        frame.size.height = max(frame.height, lineHeight.rounded(.up))
        textView.minSize = frame.size
        textView.maxSize = NSSize(width: frame.width, height: max(frame.height, maxBottom - frame.minY))
        textView.frame = frame
        onChange?()
    }

    /// Applies a changed style and color to the selection (or the typing attributes), and the
    /// background to the whole box.
    func apply(style newStyle: TextStyle, color newColor: RGBA, background: RGBA) {
        applyBackground(style: newStyle, background: background)
        let old = style
        style = newStyle
        let fontChanged = old.family != newStyle.family || old.points != newStyle.points || old.bold != newStyle.bold || old.italic != newStyle.italic
        let changes = (font: fontChanged, underline: old.underline != newStyle.underline,
                       strikethrough: old.strikethrough != newStyle.strikethrough, color: color != newColor)
        color = newColor
        textView.insertionPointColor = newColor.nsColor
        guard changes.font || changes.underline || changes.strikethrough || changes.color else {
            onChange?()
            return
        }

        func update(_ attributes: inout [NSAttributedString.Key: Any]) {
            if changes.font {
                let font = attributes[.font] as? NSFont ?? old.font
                attributes[.font] = Self.convert(font, from: old, to: newStyle)
            }
            if changes.underline { attributes[.underlineStyle] = newStyle.underline ? NSUnderlineStyle.single.rawValue : 0 }
            if changes.strikethrough { attributes[.strikethroughStyle] = newStyle.strikethrough ? NSUnderlineStyle.single.rawValue : 0 }
            if changes.color { attributes[.foregroundColor] = newColor.nsColor }
        }

        let range = textView.selectedRange()
        if range.length > 0, let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                var attributes = attributes
                update(&attributes)
                storage.setAttributes(attributes, range: run)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        var typing = textView.typingAttributes
        update(&typing)
        textView.typingAttributes = typing
        onChange?()
    }

    private func applyBackground(style: TextStyle, background: RGBA) {
        textView.drawsBackground = style.opaque
        textView.backgroundColor = background.nsColor
        textView.insertionPointColor = color.nsColor
    }

    /// `font` with only the parts of the style that changed between `old` and `new` replaced.
    private static func convert(_ font: NSFont, from old: TextStyle, to new: TextStyle) -> NSFont {
        let manager = NSFontManager.shared
        var font = font
        if old.family != new.family { font = manager.convert(font, toFamily: new.family) }
        if old.points != new.points { font = manager.convert(font, toSize: new.pixelSize) }
        if old.bold != new.bold { font = new.bold ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask) }
        if old.italic != new.italic { font = new.italic ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask) }
        return font
    }

    private static func attributes(_ style: TextStyle, _ color: RGBA) -> [NSAttributedString.Key: Any] {
        [
            .font: style.font,
            .foregroundColor: color.nsColor,
            .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0,
        ]
    }

    /// The style of the characters at the start of the selection (or of what will be typed).
    private func styleAtSelection() -> TextStyle {
        let range = textView.selectedRange()
        let attributes = range.length > 0 && range.location < (textView.textStorage?.length ?? 0)
            ? textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? textView.typingAttributes
            : textView.typingAttributes
        var read = style
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            read.family = font.familyName ?? read.family
            read.points = (font.pointSize * 3 / 4).rounded()
            read.bold = traits.contains(.boldFontMask)
            read.italic = traits.contains(.italicFontMask)
        }
        read.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        read.strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        return read
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

    func textViewDidChangeSelection(_ notification: Notification) {
        let read = styleAtSelection()
        guard read != style else { return }
        style = read
        onSelectionStyle?(read)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel?()
        return true
    }
}
