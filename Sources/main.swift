// main.swift — Application entry point.
//
// macOS apps need an NSApplication to manage the event loop and system
// integration. We configure it as an "accessory" app (LSUIElement) so it
// lives in the menu bar without a Dock icon.

import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
