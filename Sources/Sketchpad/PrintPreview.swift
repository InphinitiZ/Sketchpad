import AppKit
import PaintCore

/// How a picture falls on paper: its printed size (a pixel is 72/dpi points, times the scale or
/// the Fit To setting) cut into tiles of the printable area, page after page across and then
/// down, centered on the page when the settings say so.
struct PrintLayout: Equatable {
    /// The paper, in points.
    let paperSize: NSSize
    /// The printable area of each page, in page coordinates from the top-left.
    let printable: NSRect
    /// The picture's size on paper, in points.
    let pictureSize: NSSize
    let columns: Int
    let rows: Int
    /// Where the picture starts within the printable area (non-zero when centered).
    let offset: NSPoint

    var pageCount: Int { columns * rows }

    init(pixelWidth: Int, pixelHeight: Int, dotsPerInch: Double, info: NSPrintInfo) {
        paperSize = info.paperSize
        printable = NSRect(origin: NSPoint(x: info.leftMargin, y: info.topMargin), size: PageSetupAccessory.printableSize(of: info))
        let natural = NSSize(width: Double(pixelWidth) * 72 / dotsPerInch, height: Double(pixelHeight) * 72 / dotsPerInch)
        let scale = PageSetupAccessory.fitScale(for: natural, info: info) ?? info.scalingFactor
        pictureSize = NSSize(width: natural.width * scale, height: natural.height * scale)
        columns = max(1, Int((pictureSize.width / printable.width).rounded(.up)))
        rows = max(1, Int((pictureSize.height / printable.height).rounded(.up)))
        offset = NSPoint(
            x: info.isHorizontallyCentered && columns == 1 ? (printable.width - pictureSize.width) / 2 : 0,
            y: info.isVerticallyCentered && rows == 1 ? (printable.height - pictureSize.height) / 2 : 0
        )
    }

    /// Where the whole picture lies relative to page `index`'s top-left corner: pages show
    /// the printable-area-sized tile of it at their column and row.
    func pictureFrame(onPage index: Int) -> NSRect {
        let column = index % columns, row = index / columns
        return NSRect(
            x: printable.minX + offset.x - CGFloat(column) * printable.width,
            y: printable.minY + offset.y - CGFloat(row) * printable.height,
            width: pictureSize.width, height: pictureSize.height
        )
    }
}

/// Paint's print preview (MFC's `CPreviewView`): the pages as they will print, one or two at a
/// time, fitted to the window or zoomed in. Clicking a page zooms in a step there, and from the
/// last step back out.
final class PrintPreviewView: NSView {
    enum Zoom: Int, CaseIterable {
        case fit, actual, double
    }

    private var image: CGImage
    private(set) var layout: PrintLayout
    private(set) var page = 0
    var zoom = Zoom.fit { didSet { updateSize() } }
    var showsTwoPages = false { didSet { updateSize() } }
    var onChange: (() -> Void)?
    /// Esc leaves the preview.
    var onClose: (() -> Void)?

    private static let gap: CGFloat = 24

    init(image: CGImage, layout: PrintLayout) {
        self.image = image
        self.layout = layout
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(localized("Print preview"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(image: CGImage? = nil, layout: PrintLayout) {
        if let image { self.image = image }
        self.layout = layout
        page = min(page, layout.pageCount - 1)
        updateSize()
    }

    /// Two pages side by side only when they fit and there is a second one.
    var pagesShown: Int { showsTwoPages && zoom == .fit && page + 1 < layout.pageCount ? 2 : 1 }
    var canGoBack: Bool { page > 0 }
    var canGoForward: Bool { page + pagesShown < layout.pageCount }

    func nextPage() {
        guard canGoForward else { return }
        page += pagesShown
        updateSize()
    }

    func previousPage() {
        guard canGoBack else { return }
        page = max(0, page - (showsTwoPages && zoom == .fit ? 2 : 1))
        updateSize()
    }

    /// Screen points per paper point.
    var scale: CGFloat {
        switch zoom {
        case .actual: return 1
        case .double: return 2
        case .fit:
            guard let clip = enclosingScrollView?.contentSize else { return 1 }
            let count = CGFloat(pagesShown)
            let across = (clip.width - Self.gap * (count + 1)) / (layout.paperSize.width * count)
            let down = (clip.height - Self.gap * 2) / layout.paperSize.height
            return max(0.05, min(across, down))
        }
    }

    func updateSize() {
        let scale = scale, count = CGFloat(pagesShown)
        let content = NSSize(
            width: layout.paperSize.width * scale * count + Self.gap * (count + 1),
            height: layout.paperSize.height * scale + Self.gap * 2
        )
        let clip = enclosingScrollView?.contentSize ?? content
        setFrameSize(NSSize(width: max(content.width, clip.width), height: max(content.height, clip.height)))
        needsDisplay = true
        onChange?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateSize()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        if zoom == .fit { updateSize() }
    }

    /// Where each shown page lies in the view.
    var paperRects: [(page: Int, rect: NSRect)] {
        let scale = scale, count = pagesShown
        let size = NSSize(width: layout.paperSize.width * scale, height: layout.paperSize.height * scale)
        let total = size.width * CGFloat(count) + Self.gap * CGFloat(count - 1)
        let x = max(Self.gap, (bounds.width - total) / 2)
        let y = max(Self.gap, (bounds.height - size.height) / 2)
        return (0..<count).map { (page + $0, NSRect(origin: NSPoint(x: x + CGFloat($0) * (size.width + Self.gap), y: y), size: size)) }
    }

    /// Zooms in a step on the clicked page, keeping the clicked spot under the pointer, or
    /// from the largest step back out.
    func click(at point: NSPoint) {
        guard let hit = paperRects.first(where: { $0.rect.contains(point) }) else { return }
        let spot = NSPoint(x: (point.x - hit.rect.minX) / hit.rect.width, y: (point.y - hit.rect.minY) / hit.rect.height)
        let visible = visibleRect, offset = NSPoint(x: point.x - visible.minX, y: point.y - visible.minY)
        page = hit.page
        zoom = zoom == .double ? .fit : Zoom(rawValue: zoom.rawValue + 1)!
        guard let paper = paperRects.first?.rect else { return }
        scroll(NSPoint(x: paper.minX + spot.x * paper.width - offset.x, y: paper.minY + spot.y * paper.height - offset.y))
    }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = scale
        for (index, paper) in paperRects {
            NSColor(white: 0, alpha: 0.35).setFill()
            paper.offsetBy(dx: 3, dy: 3).fill()
            NSColor.white.setFill()
            paper.fill()

            context.saveGState()
            let printable = NSRect(x: paper.minX + layout.printable.minX * scale, y: paper.minY + layout.printable.minY * scale,
                                   width: layout.printable.width * scale, height: layout.printable.height * scale)
            context.clip(to: printable)
            let frame = layout.pictureFrame(onPage: index)
            let picture = NSRect(x: paper.minX + frame.minX * scale, y: paper.minY + frame.minY * scale,
                                 width: frame.width * scale, height: frame.height * scale)
            context.interpolationQuality = .medium
            context.translateBy(x: 0, y: picture.maxY + picture.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: picture)
            context.restoreGState()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 121: nextPage() // Page Down
        case 116: previousPage() // Page Up
        case 124 where zoom == .fit: nextPage() // → when the whole page shows; zoomed in, arrows scroll
        case 123 where zoom == .fit: previousPage() // ←
        case 53: onClose?() // Esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
