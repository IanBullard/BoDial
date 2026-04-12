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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceMonitor: DeviceMonitor!
    private var eventTap: ScrollEventTap!

    // Menu items we need to update dynamically.
    private var statusMenuItem: NSMenuItem!
    private var sliderMenuItem: NSMenuItem!
    private var valueLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Start device monitoring (reads raw HID, injects scaled events).
        deviceMonitor.start()

        // Start event tap (suppresses original BoDial scroll events).
        if !eventTap.start() {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "BoDial needs Accessibility access to suppress the device's native scroll events and replace them with properly scaled ones.\n\nGrant permission in:\nSystem Settings > Privacy & Security > Accessibility"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            NSApp.terminate(nil)
        }

        updateStatusDisplay()
        print("[BoDial] Running. Look for the dial icon in the menu bar.")
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
