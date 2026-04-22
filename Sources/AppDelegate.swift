// AppDelegate.swift — Menu bar UI for BoDial.
//
// Status bar item with a dropdown menu containing:
// - Device connection status
// - Quit button
//
// Uses AppKit (NSMenu, NSStatusItem) directly — no SwiftUI dependency,
// which keeps the build simple and compatible with macOS 13+.

import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceMonitor: DeviceMonitor!

    // Menu items we need to update dynamically.
    private var statusMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("Startup: pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        log.notice("Startup: bundlePath=\(Bundle.main.bundlePath, privacy: .public)")
        log.notice("Startup: executablePath=\(Bundle.main.executablePath ?? "<nil>", privacy: .public)")

        // Preflight TCC before touching any HID or event-posting API so the
        // user sees both prompts up front instead of tripping over them in
        // sequence. Input Monitoring is needed to seize the dial;
        // Accessibility is needed to post synthesized scroll events.
        let status = Permissions.check()
        if !status.isGranted {
            log.notice("Startup: missing permissions, presenting alert and exiting")
            Permissions.presentMissingAlert(status)
            NSApp.terminate(nil)
            return
        }
        log.notice("Startup: permissions granted, continuing")

        deviceMonitor = DeviceMonitor()
        deviceMonitor.onConnectionChanged = { [weak self] _ in
            self?.updateStatusDisplay()
        }

        // Build the menu bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dial.low", accessibilityDescription: "BoDial")
        }

        let menu = NSMenu()

        // -- Status display --
        statusMenuItem = NSMenuItem(title: "Searching...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // -- Quit --
        let quitItem = NSMenuItem(title: "Quit BoDial", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Start device monitoring — seizes the dial and synthesizes
        // scroll events from its raw HID reports.
        deviceMonitor.start()

        updateStatusDisplay()
        log.notice("Running. Menu bar icon installed.")
    }

    private func updateStatusDisplay() {
        if deviceMonitor.isConnected {
            statusMenuItem.title = "BoDial: Connected"
        } else {
            statusMenuItem.title = "BoDial: Not connected"
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicit teardown ensures the IOHIDManager is closed before the
        // process exits, releasing the seize cleanly and letting the OS HID
        // driver resume. NOTE: not called on force-quit (SIGKILL) — the
        // Mach ports still get released by the kernel, but the driver
        // handover can lag until the dial is re-enumerated (unplug/replug).
        log.notice("Shutdown: beginning teardown")
        deviceMonitor?.stop()
        log.notice("Shutdown: complete")
    }
}
