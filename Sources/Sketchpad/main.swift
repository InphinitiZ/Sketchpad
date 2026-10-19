import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build()
app.setActivationPolicy(.regular)
app.run()
