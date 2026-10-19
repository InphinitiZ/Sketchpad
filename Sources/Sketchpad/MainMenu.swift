import AppKit

/// The menu bar, built in code since the project has no storyboard.
enum MainMenu {
    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addItem(submenu(appName, [
            item(localized(format: "About %@", appName), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(localized(format: "Hide %@", appName), #selector(NSApplication.hide(_:)), "h"),
            item(localized("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(localized("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(localized(format: "Quit %@", appName), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        // AppKit fills "Open Recent" itself once it finds a clearRecentDocuments: item.
        let openRecent = submenu(localized("Open Recent"), [
            item(localized("Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:))),
        ])
        // AppKit fills this item with Continuity Camera's choices (Take Photo, Scan Documents…).
        let fromDevice = NSMenuItem(title: localized("Import from iPhone or iPad"), action: nil, keyEquivalent: "")
        fromDevice.identifier = NSMenuItem.importFromDeviceIdentifier
        main.addItem(submenu(localized("File"), [
            item(localized("New"), #selector(NSDocumentController.newDocument(_:)), "n"),
            item(localized("Open…"), #selector(NSDocumentController.openDocument(_:)), "o"),
            openRecent,
            .separator(),
            item(localized("From Scanner or Camera…"), #selector(AppDelegate.importFromScannerOrCamera(_:))),
            fromDevice,
            item(localized("Send in Email…"), #selector(CanvasDocument.sendInEmail(_:))),
            submenu(localized("Set as Desktop Background"), [
                item(localized("Fill"), #selector(CanvasDocument.setDesktopBackgroundFill(_:))),
                item(localized("Tile"), #selector(CanvasDocument.setDesktopBackgroundTile(_:))),
                item(localized("Center"), #selector(CanvasDocument.setDesktopBackgroundCenter(_:))),
            ]),
            .separator(),
            item(localized("Close"), #selector(NSWindow.performClose(_:)), "w"),
            item(localized("Save"), #selector(NSDocument.save(_:)), "s"),
            item(localized("Save As…"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item(localized("Revert to Saved"), #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item(localized("Image Properties…"), #selector(CanvasView.showImageProperties(_:)), "e"),
            .separator(),
            item(localized("Page Setup…"), #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item(localized("Print Preview"), #selector(CanvasWindowController.togglePrintPreview(_:))),
            item(localized("Print…"), #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        main.addItem(submenu(localized("Edit"), [
            item(localized("Undo"), Selector(("undo:")), "z"),
            item(localized("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(localized("Cut"), #selector(CanvasView.cut(_:)), "x"),
            item(localized("Copy"), #selector(CanvasView.copy(_:)), "c"),
            item(localized("Paste"), #selector(CanvasView.paste(_:)), "v"),
            item(localized("Paste From…"), #selector(CanvasView.pasteFrom(_:))),
            item(localized("Delete"), #selector(CanvasView.delete(_:))),
            item(localized("Select All"), #selector(NSText.selectAll(_:)), "a"),
            item(localized("Invert Selection"), #selector(CanvasView.invertSelection(_:))),
            .separator(),
            item(localized("Transparent Selection"), #selector(CanvasWindowController.toggleTransparentSelection(_:))),
        ]))

        // Each command acts on the selection if there is one, else on the whole picture.
        main.addItem(submenu(localized("Image"), [
            item(localized("Crop to Selection"), #selector(CanvasView.crop(_:)), "x", [.command, .shift]),
            item(localized("Resize and Skew…"), #selector(CanvasView.resizeAndSkew(_:)), "r", [.command, .option]),
            .separator(),
            item(localized("Rotate Right 90°"), #selector(CanvasView.rotateRight(_:))),
            item(localized("Rotate Left 90°"), #selector(CanvasView.rotateLeft(_:))),
            item(localized("Rotate 180°"), #selector(CanvasView.rotateHalfTurn(_:))),
            .separator(),
            item(localized("Flip Vertical"), #selector(CanvasView.flipVertical(_:))),
            item(localized("Flip Horizontal"), #selector(CanvasView.flipHorizontal(_:))),
            .separator(),
            item(localized("Invert Color"), #selector(CanvasView.invertColor(_:)), "i", [.command, .shift]),
            .separator(),
            item(localized("Larger Size"), #selector(CanvasView.largerSize(_:)), "]"),
            item(localized("Smaller Size"), #selector(CanvasView.smallerSize(_:)), "["),
        ]))

        // Paint's text box takes Ctrl+B, Ctrl+I and Ctrl+U; here they are ⌘B, ⌘I and ⌘U.
        main.addItem(submenu(localized("Format"), [
            item(localized("Bold"), #selector(CanvasWindowController.toggleBold(_:)), "b"),
            item(localized("Italic"), #selector(CanvasWindowController.toggleItalic(_:)), "i"),
            item(localized("Underline"), #selector(CanvasWindowController.toggleUnderline(_:)), "u"),
            item(localized("Strikethrough"), #selector(CanvasWindowController.toggleStrikethrough(_:))),
        ]))

        main.addItem(submenu(localized("View"), [
            item(localized("Zoom In"), #selector(CanvasWindowController.zoomIn(_:)), "="),
            item(localized("Zoom Out"), #selector(CanvasWindowController.zoomOut(_:)), "-"),
            item(localized("Actual Size"), #selector(CanvasWindowController.zoomToActualSize(_:)), "0"),
            .separator(),
            // ⌘R is Paint's Ctrl+R; ⌘' is the Mac's usual grid shortcut (⌘G is Find Next).
            item(localized("Rulers"), #selector(CanvasWindowController.toggleRulers(_:)), "r"),
            item(localized("Gridlines"), #selector(CanvasWindowController.toggleGridlines(_:)), "'"),
            item(localized("Status Bar"), #selector(CanvasWindowController.toggleStatusBar(_:))),
            .separator(),
            item(localized("Full Screen"), #selector(CanvasWindowController.showFullScreen(_:)), String(UnicodeScalar(NSF11FunctionKey)!), []),
            item(localized("Thumbnail"), #selector(CanvasWindowController.toggleThumbnail(_:))),
        ]))

        let window = submenu(localized("Window"), [
            item(localized("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(localized("Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(localized("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        return main
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
