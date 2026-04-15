// AppDelegate.swift — Menu bar UI for BoDial.
//
// Creates a status bar item (menu bar icon) with a dropdown menu containing:
// - Device connection status
// - Sensitivity slider (1-100%, persisted to UserDefaults)
// - Quit button
//
// Uses AppKit (NSMenu, NSStatusItem) directly — no SwiftUI dependency,
// which keeps the build simple and compatible with macOS 13+.

import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceMonitor: DeviceMonitor!
    private var eventTap: ScrollEventTap!

    // Menu items we need to update dynamically.
    private var statusMenuItem: NSMenuItem!
    private var sliderMenuItem: NSMenuItem!
    private var valueLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("Startup: pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        log.notice("Startup: bundlePath=\(Bundle.main.bundlePath, privacy: .public)")
        log.notice("Startup: executablePath=\(Bundle.main.executablePath ?? "<nil>", privacy: .public)")

        // Preflight both TCC grants before touching any HID or event-tap API.
        // Doing this up front means the user sees one consolidated prompt
        // instead of tripping over each gate in sequence across relaunches.
        let status = Permissions.check()
        if !status.bothGranted {
            log.notice("Startup: missing permissions, presenting alert and exiting")
            Permissions.presentMissingAlert(status)
            NSApp.terminate(nil)
            return
        }
        log.notice("Startup: all permissions granted, continuing")

        deviceMonitor = DeviceMonitor()
        eventTap = ScrollEventTap(deviceMonitor: deviceMonitor)

        deviceMonitor.onConnectionChanged = { [weak self] connected in
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

        // -- Sensitivity slider --
        let sliderView = makeSliderView()
        sliderMenuItem = NSMenuItem()
        sliderMenuItem.view = sliderView
        menu.addItem(sliderMenuItem)
        menu.addItem(NSMenuItem.separator())

        // -- Quit --
        let quitItem = NSMenuItem(title: "Quit BoDial", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Listen for a second launch attempt so we can pop the menu open.
        // This lets users access settings even when the icon is hidden.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(bringUpMenu),
            name: NSNotification.Name(bringUpNotificationName), object: nil)

        // Start device monitoring (reads raw HID, injects scaled events).
        deviceMonitor.start()

        // Start event tap (suppresses original BoDial scroll events).
        // Preflight already confirmed Accessibility is granted, so a failure
        // here is unexpected — surface it and bail rather than silently
        // continuing without suppression.
        if !eventTap.start() {
            log.error("eventTap.start() failed despite Accessibility being granted")
            let alert = NSAlert()
            alert.messageText = "BoDial failed to install its event tap"
            alert.informativeText = "Accessibility is granted but CGEvent.tapCreate still failed. Check Console.app for BoDial log lines and file a bug."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }

        updateStatusDisplay()
        log.notice("Running. Menu bar icon installed.")
    }

    // Builds the slider + label view embedded in the menu.
    private func makeSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 50))

        let label = NSTextField(labelWithString: "Sensitivity:")
        label.frame = NSRect(x: 16, y: 28, width: 80, height: 16)
        label.font = NSFont.systemFont(ofSize: 12)

        valueLabel = NSTextField(labelWithString: "")
        valueLabel.frame = NSRect(x: 190, y: 28, width: 44, height: 16)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right

        let stored = UserDefaults.standard.integer(forKey: "scrollScale")
        let initial = stored > 0 ? stored : 5

        let slider = NSSlider(value: Double(initial), minValue: 1, maxValue: 100,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 16, y: 4, width: 218, height: 24)
        slider.isContinuous = true

        container.addSubview(label)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        updateValueLabel(initial)

        return container
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue)
        UserDefaults.standard.set(value, forKey: "scrollScale")
        updateValueLabel(value)
    }

    private func updateValueLabel(_ value: Int) {
        valueLabel.stringValue = "\(value)%"
    }

    private func updateStatusDisplay() {
        if deviceMonitor.isConnected {
            statusMenuItem.title = "BoDial: Connected"
        } else {
            statusMenuItem.title = "BoDial: Not connected"
        }
    }

    @objc private func bringUpMenu(_ note: Notification) {
        log.notice("bringUpMenu: notification received")
        if let button = statusItem.button {
            log.notice("bringUpMenu: button exists, calling performClick")
            button.performClick(nil)
        } else {
            log.warning("bringUpMenu: statusItem.button is nil")
        }
    }

    // Called by Launch Services when the user re-launches an already-running app
    // (e.g. via Spotlight or Finder). For installed apps in /Applications, macOS
    // won't start a second process — it calls this instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.notice("applicationShouldHandleReopen: popping menu")
        statusItem.button?.performClick(nil)
        return false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicit teardown ensures the CGEventTap and IOHIDManager are torn down
        // before the process exits. Without this, a rapid relaunch can race against
        // kernel-side cleanup and install a second tap on cghidEventTap.
        // NOTE: not called on force-quit (SIGKILL) — zombie taps are still possible
        // in that path, and a logout/login is the only recovery.
        log.notice("Shutdown: beginning teardown")
        eventTap?.stop()
        deviceMonitor?.stop()
        log.notice("Shutdown: complete")
    }
}
