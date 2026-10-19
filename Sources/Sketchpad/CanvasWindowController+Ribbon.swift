import AppKit
import PaintCore

/// The ribbon controls that reflect the editor state.
struct RibbonControls {
    var tools: [Tool: RibbonButton] = [:]
    var select: RibbonButton?
    var brushes: RibbonButton?
    var size: RibbonButton?
    var shapes: RibbonGallery?
    var outline: RibbonButton?
    var fill: RibbonButton?
    /// Color 1, Color 2 and the palette appear on both the Home and Text tabs.
    var color1: [RibbonButton] = []
    var color2: [RibbonButton] = []
    var palettes: [PaletteView] = []
    var rulers: NSButton?
    var gridlines: NSButton?
    var statusBar: NSButton?
    var thumbnail: RibbonButton?
    var fontFamily: NSComboBox?
    var fontSize: NSComboBox?
    var bold: RibbonButton?
    var italic: RibbonButton?
    var underline: RibbonButton?
    var strikethrough: RibbonButton?
    var opaque: RibbonButton?
    var transparent: RibbonButton?
    var textTab = 2
    var previewTab = 3
    var onePage: RibbonButton?
    var twoPages: RibbonButton?
    var previousPage: RibbonButton?
    var nextPage: RibbonButton?
}

/// Builds Paint's ribbon (from the decoded `UIFILE_MSPAINT`): Home, View and the contextual
/// Text tab, with the same groups and commands in the same order.
extension CanvasWindowController {
    func buildRibbon() -> RibbonView {
        let ribbon = RibbonView { [weak self] in self?.fileMenu() ?? NSMenu() }
        ribbon.addTab(.init(title: localized("Home"), contextual: false, groups: homeGroups()))
        ribbon.addTab(.init(title: localized("View"), contextual: false, groups: viewGroups()))
        controls.textTab = 2
        ribbon.addTab(.init(title: localized("Text"), contextual: true, groups: textGroups()))
        ribbon.setTab(controls.textTab, visible: false)
        controls.previewTab = 3
        ribbon.addTab(.init(title: localized("Print Preview"), contextual: false, groups: previewGroups()))
        ribbon.setTab(controls.previewTab, visible: false)
        return ribbon
    }

    // MARK: - Home

    private func homeGroups() -> [NSView] {
        [clipboardGroup(withPasteFrom: true), imageGroup(), toolsGroup(), brushesGroup(), shapesGroup(), sizeGroup(), colorsGroup()]
    }

    private func clipboardGroup(withPasteFrom: Bool) -> NSView {
        let pasteImage = RibbonIcons.symbol("doc.on.clipboard", size: 32, color: .systemBrown)
        let paste: RibbonButton
        if withPasteFrom {
            paste = RibbonButton(title: localized("Paste"), image: pasteImage, size: .large, kind: .split({ [weak self] in
                self?.menu([
                    (localized("Paste"), #selector(CanvasView.paste(_:))),
                    (localized("Paste from"), #selector(CanvasView.pasteFrom(_:))),
                ]) ?? NSMenu()
            }))
        } else {
            paste = RibbonButton(title: localized("Paste"), image: pasteImage, size: .large)
        }
        paste.action = #selector(CanvasView.paste(_:))
        let cut = small(localized("Cut"), "scissors", #selector(CanvasView.cut(_:)))
        let copy = small(localized("Copy"), "doc.on.doc", #selector(CanvasView.copy(_:)))
        describe(paste, "⌘V", localized("Paste the contents of the Clipboard."))
        describe(cut, "⌘X", localized("Cut the selection and put it on the Clipboard."))
        describe(copy, "⌘C", localized("Copy the selection to the Clipboard."))
        // Collapse orders come from the groups' scaling values in UIFILE_MSPAINT (the high
        // byte: Clipboard 1, Image 2, Tools 3, Shapes 4 on Home); groups without one keep
        // their size.
        return RibbonGroup(title: localized("Clipboard"), content: row([paste, column([cut, copy])]),
                           icon: RibbonIcons.symbol("doc.on.clipboard", size: 32, color: .systemBrown), collapseOrder: 1)
    }

    private func imageGroup() -> NSView {
        let select = RibbonButton(
            title: localized("Select"), image: RibbonIcons.symbol("rectangle.dashed", size: 32, color: .controlAccentColor),
            size: .large, kind: .split({ [weak self] in self?.selectMenu() ?? NSMenu() })
        ) { [weak self] in
            guard let self else { return }
            // The top half picks the selection tool again, keeping its last shape.
            if !self.state.tool.isSelection { self.state.tool = self.state.lastSelectionTool }
        }
        controls.select = select
        let crop = small(localized("Crop"), "crop", #selector(CanvasView.crop(_:)))
        let resize = small(localized("Resize"), "arrow.up.left.and.arrow.down.right", #selector(CanvasView.resizeAndSkew(_:)))
        let rotate = RibbonButton(
            title: localized("Rotate"), image: RibbonIcons.symbol("rotate.right", size: 16), size: .small,
            kind: .menu({ [weak self] in self?.canvasView.rotateMenu() ?? NSMenu() })
        )
        describe(select, nil, localized("Select part of the picture to move, copy or change it."))
        describe(crop, "⇧⌘X", localized("Crop the picture to the selection."))
        describe(resize, "⌥⌘R", localized("Resize and skew the picture or the selection."))
        describe(rotate, nil, localized("Rotate or flip the picture or the selection."))
        return RibbonGroup(title: localized("Image"), content: row([select, column([crop, resize, rotate])]),
                           icon: RibbonIcons.symbol("photo", size: 32, color: .controlAccentColor), collapseOrder: 2)
    }

    private func toolsGroup() -> NSView {
        let icons: [Tool: NSImage] = [
            .pencil: RibbonIcons.symbol("pencil", size: 16, color: .systemOrange),
            .fill: RibbonIcons.fillBucket(size: 16),
            .text: RibbonIcons.symbol("textformat", size: 16, color: .labelColor),
            .eraser: RibbonIcons.symbol("eraser", size: 16, color: .systemPink),
            .picker: RibbonIcons.symbol("eyedropper", size: 16, color: .systemTeal),
            .magnifier: RibbonIcons.symbol("magnifyingglass", size: 16, color: .systemIndigo),
        ]
        let rows: [[Tool]] = [[.pencil, .fill, .text], [.eraser, .picker, .magnifier]]
        let grid = column(rows.map { tools in
            row(tools.map { tool in
                let button = RibbonButton(title: tool.title, image: icons[tool], size: .iconOnly, kind: .toggle) { [weak self] in
                    self?.state.tool = tool
                }
                describe(button, tool.shortcut.map { String($0).uppercased() }, Self.toolDetail(tool))
                controls.tools[tool] = button
                return button
            }, spacing: 2)
        }, spacing: 2)
        return RibbonGroup(title: localized("Tools"), content: grid,
                           icon: RibbonIcons.symbol("pencil", size: 32, color: .systemOrange), collapseOrder: 3)
    }

    /// Paint's Brushes button has no group caption; its menu is a gallery of the nine brushes.
    private func brushesGroup() -> NSView {
        let brushes = RibbonButton(
            title: localized("Brushes"), image: Self.brushIcon(state.brushKind), size: .large,
            kind: .split({ [weak self] in self?.galleryMenu(brushes: true) ?? NSMenu() })
        ) { [weak self] in
            self?.state.tool = .brush
        }
        controls.brushes = brushes
        describe(brushes, nil, localized("Paint with one of the brushes."))
        return RibbonGroup(title: "", content: brushes)
    }

    private func shapesGroup() -> NSView {
        let items = ShapeKind.allCases.map { RibbonGallery.Item(title: $0.title, image: RibbonIcons.shape($0)) }
        let gallery = RibbonGallery(items: items, columns: 8, cell: NSSize(width: 21, height: 21))
        gallery.setAccessibilityLabel(localized("Shapes"))
        gallery.onSelect = { [weak self] index in
            self?.state.shapeKind = ShapeKind.allCases[index]
            self?.state.tool = .shape
        }
        controls.shapes = gallery
        let outline = RibbonButton(
            title: localized("Outline"), image: RibbonIcons.outline(size: 16), size: .small,
            kind: .menu({ [weak self] in self?.shapePaintMenu(outline: true) ?? NSMenu() })
        )
        let fill = RibbonButton(
            title: localized("Fill"), image: RibbonIcons.fill(size: 16), size: .small,
            kind: .menu({ [weak self] in self?.shapePaintMenu(outline: false) ?? NSMenu() })
        )
        controls.outline = outline
        controls.fill = fill
        describe(outline, nil, localized("Choose the outline of shapes, drawn in color 1."))
        describe(fill, nil, localized("Choose the fill of shapes, drawn in color 2."))
        return RibbonGroup(title: localized("Shapes"), content: row([gallery, column([outline, fill])], spacing: 6),
                           icon: RibbonIcons.shape(.fivePointStar, size: 32), collapseOrder: 4)
    }

    private func sizeGroup() -> NSView {
        let size = RibbonButton(
            title: localized("Size"), image: RibbonIcons.sizes(size: 32), size: .large,
            kind: .menu({ [weak self] in self?.sizeMenu() ?? NSMenu() })
        )
        controls.size = size
        describe(size, "⌘[ ⌘]", localized("Choose the width for the selected tool."))
        return RibbonGroup(title: "", content: size)
    }

    private func colorsGroup() -> NSView {
        let color1 = RibbonButton(title: localized("Color 1"), image: RibbonIcons.swatch(state.primary, size: 32), size: .large, kind: .toggle) { [weak self] in
            self?.state.activeSlot = .primary
        }
        let color2 = RibbonButton(title: localized("Color 2"), image: RibbonIcons.swatch(state.secondary, size: 32), size: .large, kind: .toggle) { [weak self] in
            self?.state.activeSlot = .secondary
        }
        describe(color1, nil, localized("Used by the pencil, the brushes and shape outlines. Click here, then pick a color."))
        describe(color2, nil, localized("Used by the eraser and shape fills. Click here, then pick a color."))
        color1.toolTip = localized("Color 1 (foreground color)") + "\n" + localized("Used by the pencil, the brushes and shape outlines. Click here, then pick a color.")
        color2.toolTip = localized("Color 2 (background color)") + "\n" + localized("Used by the eraser and shape fills. Click here, then pick a color.")
        let palette = PaletteView()
        palette.onPick = { [weak self] color, other in self?.state.choose(color, other: other) }
        let edit = RibbonButton(title: localized("Edit colors"), image: RibbonIcons.colorWheel(size: 32), size: .large)
        describe(edit, nil, localized("Make a color of your own; it is added to the custom colors."))
        edit.action = #selector(editColors(_:))
        edit.target = self
        controls.color1.append(color1)
        controls.color2.append(color2)
        controls.palettes.append(palette)
        return RibbonGroup(title: localized("Colors"), content: row([color1, color2, palette, edit], spacing: 4),
                           icon: RibbonIcons.colorWheel(size: 32))
    }

    // MARK: - View

    private func viewGroups() -> [NSView] {
        let zoomIn = large(localized("Zoom in"), "plus.magnifyingglass", #selector(zoomIn(_:)))
        let zoomOut = large(localized("Zoom out"), "minus.magnifyingglass", #selector(zoomOut(_:)))
        let actual = large(localized("100%"), "1.magnifyingglass", #selector(zoomToActualSize(_:)))

        let rulers = NSButton(checkboxWithTitle: localized("Rulers"), target: self, action: #selector(toggleRulers(_:)))
        let gridlines = NSButton(checkboxWithTitle: localized("Gridlines"), target: self, action: #selector(toggleGridlines(_:)))
        let statusBar = NSButton(checkboxWithTitle: localized("Status bar"), target: self, action: #selector(toggleStatusBar(_:)))
        controls.rulers = rulers
        controls.gridlines = gridlines
        controls.statusBar = statusBar

        let fullScreen = large(localized("Full screen"), "arrow.up.left.and.arrow.down.right.rectangle", #selector(showFullScreen(_:)))
        let thumbnail = RibbonButton(title: localized("Thumbnail"), image: RibbonIcons.symbol("photo", size: 32, color: .systemGreen), size: .large, kind: .toggle)
        thumbnail.target = self
        thumbnail.action = #selector(toggleThumbnail(_:))
        controls.thumbnail = thumbnail
        describe(zoomIn, "⌘=", localized("Zoom in on the picture."))
        describe(zoomOut, "⌘-", localized("Zoom out of the picture."))
        describe(actual, "⌘0", localized("Show the picture at 100%."))
        describe(fullScreen, "F11", localized("Show the picture on the whole screen."))
        describe(thumbnail, nil, localized("Show a small view of the whole picture while you are zoomed in."))
        rulers.toolTip = localized("Rulers") + " (⌘R)"
        gridlines.toolTip = localized("Gridlines") + " (⌘')"
        return [
            RibbonGroup(title: localized("Zoom"), content: row([zoomIn, zoomOut, actual]),
                        icon: RibbonIcons.symbol("magnifyingglass", size: 32, color: .controlAccentColor), collapseOrder: 1),
            RibbonGroup(title: localized("Show or hide"), content: column([rulers, gridlines, statusBar], spacing: 4),
                        icon: RibbonIcons.symbol("eye", size: 32, color: .controlAccentColor), collapseOrder: 2),
            RibbonGroup(title: localized("Display"), content: row([fullScreen, thumbnail]),
                        icon: RibbonIcons.symbol("display", size: 32, color: .controlAccentColor), collapseOrder: 3),
        ]
    }

    // MARK: - Print Preview

    /// Paint's Print Preview tab, the only one shown while previewing.
    private func previewGroups() -> [NSView] {
        func button(_ title: String, _ symbol: String, _ action: Selector, kind: RibbonButton.Kind = .push) -> RibbonButton {
            let button = RibbonButton(title: title, image: RibbonIcons.symbol(symbol, size: 32, color: .controlAccentColor), size: .large, kind: kind)
            button.target = self
            button.action = action
            return button
        }
        let print = button(localized("Print"), "printer", #selector(printFromPreview(_:)))
        let setup = button(localized("Page setup"), "doc.text", #selector(pageSetupFromPreview(_:)))
        let zoomIn = button(localized("Zoom in"), "plus.magnifyingglass", #selector(zoomIn(_:)))
        let zoomOut = button(localized("Zoom out"), "minus.magnifyingglass", #selector(zoomOut(_:)))
        let onePage = button(localized("One page"), "doc", #selector(showOnePage(_:)), kind: .toggle)
        let twoPages = button(localized("Two pages"), "book", #selector(showTwoPages(_:)), kind: .toggle)
        let previous = button(localized("Previous page"), "chevron.left.square", #selector(previousPreviewPage(_:)))
        let next = button(localized("Next page"), "chevron.right.square", #selector(nextPreviewPage(_:)))
        let close = button(localized("Close print preview"), "xmark.rectangle", #selector(togglePrintPreview(_:)))
        describe(print, "⌘P", localized("Print the current picture."))
        describe(setup, nil, localized("Change the layout of the picture."))
        describe(zoomIn, "⌘=", localized("Zoom in on the current picture."))
        describe(zoomOut, "⌘-", localized("Zoom out on the current picture."))
        describe(onePage, nil, localized("Zoom the picture so that one page fits in the window."))
        describe(twoPages, nil, localized("Zoom the picture so that two pages fit in the window."))
        describe(previous, nil, localized("Go to the previous page in the picture."))
        describe(next, nil, localized("Go to the next page in the picture."))
        describe(close, "Esc", localized("Close print preview and return to your picture."))
        controls.onePage = onePage
        controls.twoPages = twoPages
        controls.previousPage = previous
        controls.nextPage = next
        return [
            RibbonGroup(title: localized("Print"), content: row([print, setup]),
                        icon: RibbonIcons.symbol("printer", size: 32, color: .controlAccentColor)),
            RibbonGroup(title: localized("Zoom"), content: row([zoomIn, zoomOut, onePage, twoPages]),
                        icon: RibbonIcons.symbol("magnifyingglass", size: 32, color: .controlAccentColor), collapseOrder: 2),
            RibbonGroup(title: localized("Preview"), content: row([previous, next]),
                        icon: RibbonIcons.symbol("doc.on.doc", size: 32, color: .controlAccentColor)),
            RibbonGroup(title: "", content: close),
        ]
    }

    // MARK: - Text

    private func textGroups() -> [NSView] {
        let family = NSComboBox()
        family.addItems(withObjectValues: NSFontManager.shared.availableFontFamilies)
        family.completes = true
        family.numberOfVisibleItems = 16
        family.widthAnchor.constraint(equalToConstant: 150).isActive = true
        family.setAccessibilityLabel(localized("Font family"))
        let size = NSComboBox()
        size.addItems(withObjectValues: TextStyle.pointSizes.map { String(Int($0)) })
        size.widthAnchor.constraint(equalToConstant: 54).isActive = true
        size.setAccessibilityLabel(localized("Font size"))
        for box in [family, size] {
            box.target = self
            box.action = #selector(fontChanged(_:))
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        controls.fontFamily = family
        controls.fontSize = size

        func effect(_ title: String, _ symbol: String, _ change: @escaping (inout TextStyle) -> Void) -> RibbonButton {
            RibbonButton(title: title, image: RibbonIcons.symbol(symbol, size: 16), size: .iconOnly, kind: .toggle) { [weak self] in
                guard let self else { return }
                var style = self.state.textStyle
                change(&style)
                self.state.textStyle = style
            }
        }
        controls.bold = effect(localized("Bold"), "bold") { $0.bold.toggle() }
        controls.italic = effect(localized("Italic"), "italic") { $0.italic.toggle() }
        controls.underline = effect(localized("Underline"), "underline") { $0.underline.toggle() }
        controls.strikethrough = effect(localized("Strikethrough"), "strikethrough") { $0.strikethrough.toggle() }
        let effects = row([controls.bold!, controls.italic!, controls.underline!, controls.strikethrough!], spacing: 2)

        let opaque = RibbonButton(title: localized("Opaque"), image: RibbonIcons.symbol("character.textbox", size: 16), size: .small, kind: .toggle) { [weak self] in
            self?.state.textStyle.opaque = true
        }
        let transparent = RibbonButton(title: localized("Transparent"), image: RibbonIcons.symbol("textformat", size: 16), size: .small, kind: .toggle) { [weak self] in
            self?.state.textStyle.opaque = false
        }
        controls.opaque = opaque
        controls.transparent = transparent
        describe(opaque, nil, localized("Fill the text box with color 2."))
        describe(transparent, nil, localized("Let the picture show through behind the text."))
        for (button, key) in [(controls.bold!, "⌘B"), (controls.italic!, "⌘I"), (controls.underline!, "⌘U")] {
            button.toolTip = button.title + " (" + key + ")"
        }
        return [
            clipboardGroup(withPasteFrom: false),
            RibbonGroup(title: localized("Font"), content: column([row([family, size], spacing: 4), effects], spacing: 6),
                        icon: RibbonIcons.symbol("textformat", size: 32, color: .controlAccentColor)),
            RibbonGroup(title: localized("Background"), content: column([opaque, transparent]),
                        icon: RibbonIcons.symbol("character.textbox", size: 32, color: .controlAccentColor)),
            colorsGroup(),
        ]
    }

    @objc private func fontChanged(_ sender: NSComboBox) {
        var style = state.textStyle
        if sender === controls.fontFamily {
            let name = sender.stringValue
            guard NSFontManager.shared.availableFontFamilies.contains(name) else { return }
            style.family = name
        } else if let points = Double(sender.stringValue), points >= 1, points <= 999 {
            style.points = CGFloat(points)
        }
        state.textStyle = style
    }

    // MARK: - Menus

    /// Paint's application menu, behind the File button.
    func fileMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, to target: NSMenu = menu) {
            target.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        func submenu(_ title: String, _ items: [(String, Selector)]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = self.menu(items)
            menu.addItem(item)
        }
        add(localized("New"), #selector(NSDocumentController.newDocument(_:)))
        add(localized("Open…"), #selector(NSDocumentController.openDocument(_:)))
        add(localized("Save"), #selector(NSDocument.save(_:)))
        submenu(localized("Save as"), [
            (localized("PNG picture"), #selector(CanvasDocument.saveAsPNG(_:))),
            (localized("JPEG picture"), #selector(CanvasDocument.saveAsJPEG(_:))),
            (localized("BMP picture"), #selector(CanvasDocument.saveAsBMP(_:))),
            (localized("GIF picture"), #selector(CanvasDocument.saveAsGIF(_:))),
            (localized("Other formats"), #selector(NSDocument.saveAs(_:))),
        ])
        menu.addItem(.separator())
        submenu(localized("Print"), [
            (localized("Print…"), #selector(NSDocument.printDocument(_:))),
            (localized("Page setup…"), #selector(NSDocument.runPageLayout(_:))),
            (localized("Print preview"), #selector(togglePrintPreview(_:))),
        ])
        add(localized("From scanner or camera…"), #selector(AppDelegate.importFromScannerOrCamera(_:)))
        add(localized("Send in email…"), #selector(CanvasDocument.sendInEmail(_:)))
        menu.addItem(.separator())
        submenu(localized("Set as desktop background"), [
            (localized("Fill"), #selector(CanvasDocument.setDesktopBackgroundFill(_:))),
            (localized("Tile"), #selector(CanvasDocument.setDesktopBackgroundTile(_:))),
            (localized("Center"), #selector(CanvasDocument.setDesktopBackgroundCenter(_:))),
        ])
        menu.addItem(.separator())
        add(localized("Properties"), #selector(CanvasView.showImageProperties(_:)))
        menu.addItem(.separator())
        add(localized("About Paint"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(localized("Exit"), #selector(NSApplication.terminate(_:)))

        // Paint lists recent pictures beside the menu; here they are a submenu.
        let recent = NSDocumentController.shared.recentDocumentURLs.prefix(9)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: localized("Recent pictures"), action: nil, keyEquivalent: "")
            let list = NSMenu()
            for (index, url) in recent.enumerated() {
                let entry = NSMenuItem(title: "\(index + 1) \(url.lastPathComponent)", action: #selector(openRecent(_:)), keyEquivalent: "")
                entry.representedObject = url
                entry.target = self
                list.addItem(entry)
            }
            item.submenu = list
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    /// The Select button's menu: selection shapes and selection options.
    private func selectMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: localized("Selection shapes")))
        for tool in [Tool.select, .freeFormSelect] {
            let item = NSMenuItem(title: tool.title, action: #selector(chooseSelectionTool(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tool.rawValue
            item.state = state.lastSelectionTool == tool ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: localized("Selection options")))
        for (title, action) in [
            (localized("Select all"), #selector(NSText.selectAll(_:))),
            (localized("Invert selection"), #selector(CanvasView.invertSelection(_:))),
            (localized("Delete"), #selector(CanvasView.delete(_:))),
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        let transparent = NSMenuItem(title: localized("Transparent selection"), action: #selector(toggleTransparentSelection(_:)), keyEquivalent: "")
        transparent.target = self
        transparent.state = state.transparentSelection ? .on : .off
        menu.addItem(transparent)
        return menu
    }

    @objc private func chooseSelectionTool(_ sender: NSMenuItem) {
        state.tool = Tool(rawValue: sender.tag) ?? .select
    }

    /// A drop-down holding a gallery (the brushes), which closes once a choice is made.
    private func galleryMenu(brushes: Bool) -> NSMenu {
        let menu = NSMenu()
        let items = BrushKind.allCases.map { RibbonGallery.Item(title: $0.title, image: Self.brushIcon($0)) }
        let gallery = RibbonGallery(items: items, columns: 3, cell: NSSize(width: 54, height: 46))
        gallery.selectedIndex = state.tool == .brush ? BrushKind.allCases.firstIndex(of: state.brushKind) : nil
        gallery.setAccessibilityLabel(localized("Brushes"))
        gallery.onSelect = { [weak self, weak menu] index in
            self?.state.brushKind = BrushKind.allCases[index]
            self?.state.tool = .brush
            menu?.cancelTracking()
        }
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: gallery.intrinsicContentSize.width + 16, height: gallery.intrinsicContentSize.height + 12)))
        gallery.frame = NSRect(origin: NSPoint(x: 8, y: 6), size: gallery.intrinsicContentSize)
        holder.addSubview(gallery)
        let item = NSMenuItem()
        item.view = holder
        menu.addItem(item)
        return menu
    }

    /// The Size drop-down: the current tool's four sizes as lines of that thickness.
    private func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for size in state.sizeOptions {
            let item = NSMenuItem(title: localized(format: "%ld px", size), action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.image = RibbonIcons.line(thickness: min(size, 30))
            item.tag = size
            item.target = self
            item.state = size == state.size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        state.size = sender.tag
    }

    /// The Outline and Fill drop-downs.
    private func shapePaintMenu(outline: Bool) -> NSMenu {
        let menu = NSMenu()
        for paint in ShapePaint.allCases {
            let item = NSMenuItem(title: paint.title(forOutline: outline), action: #selector(chooseShapePaint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (outline, paint)
            item.state = (outline ? state.shapeOutline : state.shapeFill) == paint ? .on : .off
            if let medium = paint.medium {
                item.image = Self.brushIcon(BrushKind.allCases.first { $0.medium == medium } ?? .normal, size: NSSize(width: 32, height: 16))
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseShapePaint(_ sender: NSMenuItem) {
        guard let (outline, paint) = sender.representedObject as? (Bool, ShapePaint) else { return }
        if outline { state.shapeOutline = paint } else { state.shapeFill = paint }
    }

    // MARK: - State

    func syncControls() {
        guard ribbon != nil else { return }
        for (tool, button) in controls.tools { button.isOn = state.tool == tool }
        controls.select?.isOn = state.tool.isSelection
        controls.brushes?.isOn = state.tool == .brush
        controls.brushes?.image = Self.brushIcon(state.brushKind)
        controls.shapes?.selectedIndex = state.tool == .shape ? ShapeKind.allCases.firstIndex(of: state.shapeKind) : nil
        // Outline and Fill apply to shapes only, and lines and curves are never filled.
        controls.outline?.isEnabled = state.tool == .shape
        controls.fill?.isEnabled = state.tool == .shape && state.shapeKind.canFill
        controls.size?.isEnabled = !state.sizeOptions.isEmpty
        for button in controls.color1 {
            button.isOn = state.activeSlot == .primary
            button.image = RibbonIcons.swatch(state.primary, size: 32)
        }
        for button in controls.color2 {
            button.isOn = state.activeSlot == .secondary
            button.image = RibbonIcons.swatch(state.secondary, size: 32)
        }
        for palette in controls.palettes { palette.showCustomColors(state.customColors) }
        controls.rulers?.state = scrollView.rulersVisible ? .on : .off
        controls.gridlines?.state = canvasView.showsGridlines ? .on : .off
        controls.statusBar?.state = statusBar.isHidden ? .off : .on
        controls.thumbnail?.isOn = thumbnailEnabled

        let text = state.textStyle
        ribbon.setTab(controls.textTab, visible: state.tool == .text)
        if controls.fontFamily?.currentEditor() == nil { controls.fontFamily?.stringValue = text.family }
        if controls.fontSize?.currentEditor() == nil {
            controls.fontSize?.stringValue = text.points == text.points.rounded() ? String(Int(text.points)) : String(format: "%.1f", text.points)
        }
        controls.bold?.isOn = text.bold
        controls.italic?.isOn = text.italic
        controls.underline?.isOn = text.underline
        controls.strikethrough?.isOn = text.strikethrough
        controls.opaque?.isOn = text.opaque
        controls.transparent?.isOn = !text.opaque
        syncPreviewControls()
        window?.invalidateCursorRects(for: canvasView)
    }

    // MARK: - Helpers

    /// Paint's ribbon tooltips: the command, its shortcut, and a line on what it does.
    private func describe(_ button: RibbonButton, _ shortcut: String?, _ detail: String) {
        button.toolTip = button.title + (shortcut.map { " (\($0))" } ?? "") + "\n" + detail
        button.setAccessibilityHelp(detail)
    }

    private static func toolDetail(_ tool: Tool) -> String {
        switch tool {
        case .pencil: localized("Draw free-form lines with the selected size.")
        case .fill: localized("Fill an area with color 1, or color 2 with the right button.")
        case .text: localized("Add text to the picture.")
        case .eraser: localized("Erase to color 2; with the right button, change only color 1 into color 2.")
        case .picker: localized("Take a color from the picture for color 1, or color 2 with the right button.")
        case .magnifier: localized("Zoom in on part of the picture; the right button zooms out.")
        case .select, .freeFormSelect, .brush, .shape: tool.title
        }
    }

    private static var brushIcons: [BrushKind: NSImage] = [:]

    static func brushIcon(_ kind: BrushKind, size: NSSize = NSSize(width: 32, height: 32)) -> NSImage {
        if size.width == 32, size.height == 32, let cached = brushIcons[kind] { return cached }
        let icon = RibbonIcons.brush(kind, size: size)
        if size.width == 32, size.height == 32 { brushIcons[kind] = icon }
        return icon
    }

    private func menu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items { menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: "")) }
        return menu
    }

    private func small(_ title: String, _ symbol: String, _ action: Selector) -> RibbonButton {
        let button = RibbonButton(title: title, image: RibbonIcons.symbol(symbol, size: 16), size: .small)
        button.action = action
        return button
    }

    private func large(_ title: String, _ symbol: String, _ action: Selector) -> RibbonButton {
        let button = RibbonButton(title: title, image: RibbonIcons.symbol(symbol, size: 32, color: .controlAccentColor), size: .large)
        button.action = action
        button.target = self
        return button
    }

    private func row(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat = 1) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}
