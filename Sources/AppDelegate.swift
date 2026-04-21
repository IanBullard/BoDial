// AppDelegate.swift — Menu bar UI for BoDial.
//
// Status bar item with a dropdown menu containing:
// - Device connection status
// - Sensitivity slider (1-500%, persisted to UserDefaults)
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
    private var sliderMenuItem: NSMenuItem!
    private var valueLabel: NSTextField!

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

        // Start device monitoring — seizes the dial and synthesizes
        // scroll events from its raw HID reports.
        deviceMonitor.start()

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

        let stored = UserDefaults.standard.integer(forKey: Sensitivity.defaultsKey)
        let initial = stored > 0 ? stored : Sensitivity.defaultPct

        let slider = NSSlider(value: Double(initial),
                              minValue: Double(Sensitivity.min),
                              maxValue: Double(Sensitivity.max),
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
        UserDefaults.standard.set(value, forKey: Sensitivity.defaultsKey)
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
