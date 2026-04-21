// main.swift — Application entry point.
//
// Accessory activation policy (via LSUIElement in Info.plist) means we
// live in the menu bar with no Dock icon.

import Cocoa
import os

// Single-instance guard. A second instance's IOHIDManagerOpen(SeizeDevice)
// would fail anyway since the first already owns the dial — exit cleanly
// instead of logging a confusing error.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let first = others.first {
        log.notice("Already running (pid \(first.processIdentifier, privacy: .public)). Exiting.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
