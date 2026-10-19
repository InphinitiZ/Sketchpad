import AppKit

let app = NSApplication.shared
// The first document controller made becomes the shared one; this one adds crash recovery.
_ = DocumentController()
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build()
app.setActivationPolicy(.regular)
app.run()
