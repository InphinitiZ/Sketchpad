import AppKit

/// Building blocks for Paint's ribbon, drawn in a macOS style: a row of tabs over a band of
/// captioned groups holding large and small buttons, drop-downs, split buttons and galleries.

/// A ribbon button. Large buttons put a 32-point icon over their label; small ones put a
/// 16-point icon beside it (or show the icon alone). A button can toggle, open a menu, or
/// both (a split button acts from its top half and opens the menu from its label).
final class RibbonButton: NSControl {
    enum Size {
        case large, small, iconOnly
    }

    enum Kind {
        case push
        case toggle
        case menu(() -> NSMenu)
        case split(() -> NSMenu)
    }

    let size: Size
    let kind: Kind
    var title: String {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// For toggles: shown pressed in.
    var isOn = false {
        didSet { needsDisplay = true }
    }

    var onPress: (() -> Void)?

    private var hovering = false
    private var pressedPart: Part?
    private enum Part { case main, menu }

    init(title: String, image: NSImage?, size: Size, kind: Kind = .push, onPress: (() -> Void)? = nil) {
        self.title = title
        self.image = image
        self.size = size
        self.kind = kind
        self.onPress = onPress
        super.init(frame: .zero)
        toolTip = title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var hasMenu: Bool {
        switch kind {
        case .menu, .split: true
        case .push, .toggle: false
        }
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11)

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: Self.labelFont])
        switch size {
        case .large:
            let lines = largeLabelLines
            let width = lines.map { ($0 as NSString).size(withAttributes: [.font: Self.labelFont]).width }.max() ?? 0
            return NSSize(width: max(42, width + (hasMenu && lines.count == 1 ? 14 : 8)), height: 70)
        case .small:
            return NSSize(width: 16 + 6 + text.width + (hasMenu ? 12 : 0) + 8, height: 22)
        case .iconOnly:
            return NSSize(width: 24 + (hasMenu ? 10 : 0), height: 22)
        }
    }

    /// A large button's label wraps onto two lines at its first space, like Paint's
    /// "Edit colors"; the drop-down arrow sits after the last line.
    private var largeLabelLines: [String] {
        guard title.count > 8, let space = title.firstIndex(of: " ") else { return [title] }
        return [String(title[..<space]), String(title[title.index(after: space)...])]
    }

    /// The part of a split button that opens its menu.
    private var menuPart: NSRect {
        switch size {
        case .large: NSRect(x: 0, y: 40, width: bounds.width, height: bounds.height - 40)
        case .small, .iconOnly: NSRect(x: bounds.width - 12, y: 0, width: 12, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            highlight.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
            highlight.stroke()
        } else if pressedPart != nil, case .split = kind {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            highlight.fill()
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pressedPart == .menu ? menuPart : mainPart, xRadius: 4, yRadius: 4).fill()
        } else if pressedPart != nil {
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            highlight.fill()
        } else if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            highlight.fill()
            if case .split = kind {
                NSColor.separatorColor.setFill()
                let divider = size == .large
                    ? NSRect(x: 3, y: menuPart.minY, width: bounds.width - 6, height: 1)
                    : NSRect(x: menuPart.minX, y: 3, width: 1, height: bounds.height - 6)
                divider.fill()
            }
        }

        let alpha: CGFloat = isEnabled ? 1 : 0.35
        let textColor = NSColor.labelColor.withAlphaComponent(alpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: textColor]
        switch size {
        case .large:
            image?.draw(in: NSRect(x: (bounds.width - 32) / 2, y: 5, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            let lines = largeLabelLines
            var y: CGFloat = 40
            for (index, line) in lines.enumerated() {
                let width = (line as NSString).size(withAttributes: attributes).width
                let last = index == lines.count - 1
                let arrowRoom: CGFloat = hasMenu && last ? 9 : 0
                let x = (bounds.width - width - arrowRoom) / 2
                (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                if hasMenu && last { drawArrow(at: NSPoint(x: x + width + 6, y: y + 7), color: textColor) }
                y += 13
            }
            if hasMenu && lines.isEmpty { drawArrow(at: NSPoint(x: bounds.midX, y: 60), color: textColor) }
        case .small, .iconOnly:
            let iconX: CGFloat = size == .iconOnly ? 4 : 4
            image?.draw(in: NSRect(x: iconX, y: 3, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            if size == .small {
                (title as NSString).draw(at: NSPoint(x: 24, y: 4), withAttributes: attributes)
            }
            if hasMenu { drawArrow(at: NSPoint(x: bounds.width - 7, y: bounds.midY), color: textColor) }
        }
    }

    /// The part that acts when clicked: all of it, except a split button's menu part.
    private var mainPart: NSRect {
        guard case .split = kind else { return bounds }
        return switch size {
        case .large: NSRect(x: 0, y: 0, width: bounds.width, height: 40)
        case .small, .iconOnly: NSRect(x: 0, y: 0, width: bounds.width - 12, height: bounds.height)
        }
    }

    private func drawArrow(at point: NSPoint, color: NSColor) {
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: point.x - 3, y: point.y - 1.5))
        arrow.line(to: NSPoint(x: point.x + 3, y: point.y - 1.5))
        arrow.line(to: NSPoint(x: point.x, y: point.y + 1.5))
        arrow.close()
        color.setFill()
        arrow.fill()
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch kind {
        case let .menu(makeMenu):
            pressedPart = .menu
            needsDisplay = true
            popUp(makeMenu())
        case let .split(makeMenu) where menuPart.contains(p):
            pressedPart = .menu
            needsDisplay = true
            popUp(makeMenu())
        default:
            pressedPart = .main
            needsDisplay = true
            // Track until the mouse goes up; act only if it is still over the button.
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let inside = mainPart.contains(convert(next.locationInWindow, from: nil))
                pressedPart = inside ? .main : nil
                needsDisplay = true
                if next.type == .leftMouseUp {
                    pressedPart = nil
                    if inside { perform() }
                    break
                }
            }
        }
    }

    private func popUp(_ menu: NSMenu) {
        let origin = NSPoint(x: 0, y: bounds.height + 2)
        menu.popUp(positioning: nil, at: origin, in: self)
        pressedPart = nil
        hovering = false
        needsDisplay = true
    }

    /// Acts as if clicked (also used by VoiceOver and keyboard activation).
    func perform() {
        if case .toggle = kind { isOn.toggle() }
        onPress?()
        if let action { sendAction(action, to: target) }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch kind {
        case .push, .split: .button
        case .toggle: .checkBox
        case .menu: .menuButton
        }
    }

    override func accessibilityLabel() -> String? { title }

    private var help: String?
    override func setAccessibilityHelp(_ accessibilityHelp: String?) { help = accessibilityHelp }
    override func accessibilityHelp() -> String? { help }

    override func accessibilityValue() -> Any? {
        if case .toggle = kind { return isOn }
        return nil
    }

    override func accessibilityPerformPress() -> Bool {
        switch kind {
        case let .menu(makeMenu):
            popUp(makeMenu())
        default:
            perform()
        }
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        switch kind {
        case let .menu(makeMenu), let .split(makeMenu):
            popUp(makeMenu())
            return true
        default:
            return false
        }
    }
}

/// A captioned group of controls with a divider on its right, like a ribbon group. When the
/// window is too narrow, a group collapses into one large button that opens its controls in a
/// popover, as the Windows Ribbon does.
final class RibbonGroup: NSView {
    let title: String
    /// When this group collapses as the ribbon narrows: lower first. Groups without an order
    /// but with an icon collapse after those, right to left; groups with neither never do.
    let collapseOrder: Int?
    /// The controls and caption, shown in place or, when collapsed, in the popover.
    private let expanded = NSView()
    private var collapsedButton: RibbonButton?
    private let popover = NSPopover()
    private(set) var isCollapsed = false

    init(title: String, content: NSView, icon: NSImage? = nil, collapseOrder: Int? = nil) {
        self.title = title
        self.collapseOrder = collapseOrder
        super.init(frame: .zero)
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        for view in [content, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            expanded.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: expanded.topAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -7),
            content.bottomAnchor.constraint(lessThanOrEqualTo: caption.topAnchor, constant: -2),
            caption.leadingAnchor.constraint(equalTo: expanded.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: expanded.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: expanded.bottomAnchor, constant: -2),
            caption.widthAnchor.constraint(lessThanOrEqualTo: expanded.widthAnchor),
        ])
        if collapseOrder != nil || icon != nil {
            let button = RibbonButton(title: title, image: icon, size: .large, kind: .push) { [weak self] in self?.showPopover() }
            button.setAccessibilityRole(.menuButton)
            collapsedButton = button
            popover.behavior = .transient
        }
        show(expanded)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The group's width when shown in full, and when collapsed.
    private(set) lazy var expandedWidth: CGFloat = expanded.fittingSize.width
    var collapsedWidth: CGFloat { collapsedButton.map { $0.intrinsicContentSize.width + 13 } ?? expandedWidth }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed, let button = collapsedButton else { return }
        _ = expandedWidth
        isCollapsed = collapsed
        popover.close()
        show(collapsed ? button : expanded)
    }

    private func show(_ view: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let inset: CGFloat = view === expanded ? 0 : 6
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: view === expanded ? 0 : 4),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 1),
            view === expanded ? view.bottomAnchor.constraint(equalTo: bottomAnchor) : view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    /// The collapsed group's controls, below its button.
    func showPopover() {
        guard isCollapsed, let button = collapsedButton else { return }
        let controller = NSViewController()
        expanded.removeFromSuperview()
        expanded.translatesAutoresizingMaskIntoConstraints = true
        expanded.frame = NSRect(origin: .zero, size: expanded.fittingSize)
        controller.view = expanded
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    var isShowingPopover: Bool { popover.isShown }

    var canCollapse: Bool { collapsedButton != nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}

/// The ribbon: a row of tabs (with the File button first) over the selected tab's groups.
/// As the window narrows, groups collapse in their tab's order; when even that does not fit,
/// or the window is very small, the ribbon hides, like the Windows Ribbon (which hides below
/// 300 × 250 pixels).
final class RibbonView: NSView {
    struct Tab {
        let title: String
        /// Contextual tabs (Paint's Text tab) are tinted and appear only while they apply.
        let contextual: Bool
        let groups: [NSView]
    }

    static let minimumWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 250

    private let tabBar = NSStackView()
    private let band = NSStackView()
    private var tabs: [Tab] = []
    private var tabButtons: [NSButton] = []
    private(set) var selectedIndex = 0
    private var hiddenTabs = Set<Int>()
    /// While set, only this tab shows (Paint's print preview).
    private var exclusiveTab: Int?
    private var tabBarHeight: NSLayoutConstraint!
    private var bandHeight: NSLayoutConstraint!
    /// The ribbon is hidden because the window is too small for it.
    private(set) var isHiddenForSize = false

    init(fileMenu: @escaping () -> NSMenu) {
        super.init(frame: .zero)
        let file = RibbonFileButton(title: localized("File"), makeMenu: fileMenu)
        tabBar.addArrangedSubview(file)
        tabBar.spacing = 2
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        band.orientation = .horizontal
        band.alignment = .top
        band.spacing = 0
        band.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        band.setHuggingPriority(.defaultLow, for: .horizontal)
        band.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in [tabBar, band] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 24)
        bandHeight = band.heightAnchor.constraint(equalToConstant: 94)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBarHeight,
            band.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 2),
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bandHeight,
            band.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(localized("Ribbon"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func addTab(_ tab: Tab) {
        let index = tabs.count
        tabs.append(tab)
        let button = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
        button.tag = index
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        if tab.contextual { button.contentTintColor = .systemOrange }
        tabButtons.append(button)
        tabBar.addArrangedSubview(button)
        if tabs.count == 1 { select(0) } else { tabButtons[index].state = .off }
    }

    /// Shows or hides a contextual tab, selecting it when it appears (as Paint does for Text).
    func setTab(_ index: Int, visible: Bool) {
        guard tabs.indices.contains(index) else { return }
        let wasHidden = hiddenTabs.contains(index)
        if visible { hiddenTabs.remove(index) } else { hiddenTabs.insert(index) }
        updateTabButtons()
        guard exclusiveTab == nil else { return }
        if visible, wasHidden {
            select(index)
        } else if !visible, selectedIndex == index {
            select(0)
        }
    }

    /// Shows only `index` (Paint's Print Preview tab replaces the others), or, with `nil`, all
    /// tabs again.
    func showExclusively(_ index: Int?) {
        let previous = exclusiveTab
        exclusiveTab = index
        updateTabButtons()
        if let index {
            select(index)
        } else if let previous, selectedIndex == previous {
            select(0)
        }
    }

    private func updateTabButtons() {
        for (i, button) in tabButtons.enumerated() {
            button.isHidden = exclusiveTab.map { $0 != i } ?? hiddenTabs.contains(i)
        }
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        for (i, button) in tabButtons.enumerated() { button.state = i == index ? .on : .off }
        band.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in tabs[index].groups { band.addArrangedSubview(group) }
        lastFit = nil
        needsLayout = true
    }

    var selectedTitle: String { tabs[selectedIndex].title }

    var visibleGroups: [RibbonGroup] { tabs[selectedIndex].groups.compactMap { $0 as? RibbonGroup } }

    @objc private func tabClicked(_ sender: NSButton) {
        select(sender.tag)
    }

    // MARK: - Narrow windows

    private var lastFit: NSSize?

    override func layout() {
        super.layout()
        let size = NSSize(width: bounds.width, height: window?.contentView?.bounds.height ?? bounds.height)
        guard size != lastFit else { return }
        lastFit = size
        fit(width: size.width, windowHeight: size.height)
    }

    /// The order groups collapse in: the tab's scaling order, then the remaining groups that
    /// can collapse from right to left (the Windows Ribbon's default).
    var collapseOrder: [RibbonGroup] {
        let groups = tabs[selectedIndex].groups.compactMap { $0 as? RibbonGroup }.filter(\.canCollapse)
        let ordered = groups.filter { $0.collapseOrder != nil }.sorted { $0.collapseOrder! < $1.collapseOrder! }
        return ordered + groups.filter { $0.collapseOrder == nil }.reversed()
    }

    /// Collapses as few groups as it takes to fit `width`, in `collapseOrder`, or hides the
    /// ribbon when nothing fits.
    func fit(width: CGFloat, windowHeight: CGFloat = .greatestFiniteMagnitude) {
        let groups = tabs[selectedIndex].groups
        let order = collapseOrder
        let insets = band.edgeInsets.left + band.edgeInsets.right
        func neededWidth(collapsing count: Int) -> CGFloat {
            let collapsed = Set(order.prefix(count).map(ObjectIdentifier.init))
            return groups.reduce(insets) { total, view in
                guard let group = view as? RibbonGroup else { return total + view.fittingSize.width }
                return total + (collapsed.contains(ObjectIdentifier(group)) ? group.collapsedWidth : group.expandedWidth)
            }
        }
        let fitting = (0...order.count).first { neededWidth(collapsing: $0) <= width }
        let tooSmall = width < Self.minimumWidth || windowHeight < Self.minimumHeight || fitting == nil
        setHiddenForSize(tooSmall)
        let count = fitting ?? order.count
        for (index, group) in order.enumerated() { group.setCollapsed(index < count) }
    }

    private func setHiddenForSize(_ hidden: Bool) {
        guard hidden != isHiddenForSize else { return }
        isHiddenForSize = hidden
        tabBar.isHidden = hidden
        band.isHidden = hidden
        tabBarHeight.constant = hidden ? 0 : 24
        bandHeight.constant = hidden ? 0 : 94
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Paint's blue File button, which opens the application menu.
final class RibbonFileButton: NSButton {
    private let makeMenu: () -> NSMenu

    init(title: String, makeMenu: @escaping () -> NSMenu) {
        self.makeMenu = makeMenu
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        bezelColor = .controlAccentColor
        keyEquivalent = ""
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        target = self
        action = #selector(open)
        setAccessibilityRole(.menuButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func open() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// A grid of small choices (Paint's shape gallery and its drop-down galleries).
final class RibbonGallery: NSView {
    struct Item {
        let title: String
        let image: NSImage
    }

    fileprivate let items: [Item]
    private let columns: Int
    private let cell: NSSize
    var selectedIndex: Int? {
        didSet { needsDisplay = true }
    }
    var onSelect: ((Int) -> Void)?
    private var hoverIndex: Int?

    init(items: [Item], columns: Int, cell: NSSize) {
        self.items = items
        self.columns = columns
        self.cell = cell
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        for index in items.indices { addToolTip(frame(of: index), owner: self, userData: nil) }
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var rows: Int { (items.count + columns - 1) / columns }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * cell.width + 2, height: CGFloat(rows) * cell.height + 2)
    }

    private func frame(of index: Int) -> NSRect {
        NSRect(x: 1 + CGFloat(index % columns) * cell.width, y: 1 + CGFloat(index / columns) * cell.height, width: cell.width, height: cell.height)
    }

    fileprivate func index(at point: NSPoint) -> Int? {
        items.indices.first { frame(of: $0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        for (index, item) in items.enumerated() {
            let frame = frame(of: index)
            if index == selectedIndex || index == hoverIndex {
                (index == selectedIndex ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            let size = item.image.size
            item.image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }


    override func mouseMoved(with event: NSEvent) {
        hoverIndex = index(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        choose(index)
    }

    func choose(_ index: Int) {
        selectedIndex = index
        onSelect?(index)
    }

    override func accessibilityChildren() -> [Any]? {
        items.enumerated().map { index, item in
            let element = GalleryItemElement(gallery: self, index: index)
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityLabel(item.title)
            element.setAccessibilityValue(index == selectedIndex)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame(of: index))
            return element
        }
    }
}

extension RibbonGallery: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map { items[$0].title } ?? ""
    }
}

/// One gallery choice as VoiceOver sees it; pressing it chooses it.
private final class GalleryItemElement: NSAccessibilityElement {
    private weak var gallery: RibbonGallery?
    private let index: Int

    init(gallery: RibbonGallery, index: Int) {
        self.gallery = gallery
        self.index = index
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        gallery?.choose(index)
        return gallery != nil
    }
}
