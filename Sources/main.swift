// main.swift — Application entry point.
//
// macOS apps need an NSApplication to manage the event loop and system
// integration. We configure it as an "accessory" app (LSUIElement) so it
// lives in the menu bar without a Dock icon.

import Cocoa
import os

// Distributed notification name used to signal the running instance to show its menu.
// Declared at file scope so it's visible to AppDelegate without import.
let bringUpNotificationName = "com.ibullard.BoDial.bringUpMenu"

// Single-instance guard. If another BoDial is already running, signal it to show
// its menu (so the user can access settings even when the icon is hidden) and exit.
// Prevents duplicate event taps on cghidEventTap, which produce "confused filtering"
// where the second instance's tap sees events the first has already suppressed.
let myBundleID = Bundle.main.bundleIdentifier ?? "com.ibullard.BoDial"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    log.notice("Already running (pid \(others[0].processIdentifier, privacy: .public)). Signaling bring-up and exiting.")
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name(bringUpNotificationName),
        object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
