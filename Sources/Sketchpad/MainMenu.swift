import AppKit

/// The menu bar, built in code since the project has no storyboard.
enum MainMenu {
    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        // AppKit fills "Open Recent" itself once it finds a clearRecentDocuments: item.
        let openRecent = submenu("Open Recent", [
            item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))),
        ])
        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            openRecent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(CanvasView.cut(_:)), "x"),
            item("Copy", #selector(CanvasView.copy(_:)), "c"),
            item("Paste", #selector(CanvasView.paste(_:)), "v"),
            item("Delete", #selector(CanvasView.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Transparent Selection", #selector(CanvasWindowController.toggleTransparentSelection(_:))),
        ]))

        // Each command acts on the selection if there is one, else on the whole picture.
        main.addItem(submenu("Image", [
            item("Crop to Selection", #selector(CanvasView.crop(_:)), "x", [.command, .shift]),
            item("Resize and Skew…", #selector(CanvasView.resizeAndSkew(_:)), "r", [.command, .option]),
            .separator(),
            item("Rotate Right 90°", #selector(CanvasView.rotateRight(_:))),
            item("Rotate Left 90°", #selector(CanvasView.rotateLeft(_:))),
            item("Rotate 180°", #selector(CanvasView.rotateHalfTurn(_:))),
            .separator(),
            item("Flip Vertical", #selector(CanvasView.flipVertical(_:))),
            item("Flip Horizontal", #selector(CanvasView.flipHorizontal(_:))),
        ]))

        main.addItem(submenu("View", [
            item("Zoom In", #selector(CanvasWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(CanvasWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(CanvasWindowController.zoomToActualSize(_:)), "0"),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
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
