import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets File > Import from iPhone or iPad (Continuity Camera) hand images to the canvas.
        NSApp.registerServicesMenuSendTypes([], returnTypes: CanvasView.imageTypes)
        NSApp.activate()
    }

    @objc func importFromScannerOrCamera(_ sender: Any?) {
        DeviceImportWindowController.shared.showWindow(sender)
    }
}
