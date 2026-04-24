// AppDelegate.swift — Menu bar UI for BoDial.
//
// Status bar item with a dropdown menu containing:
// - Device connection status
// - Scrolling mode (velocity / linear) with linear-gain slider
// - Invert direction toggle
// - Quit
//
// Settings apply live: the slider is continuous and updates DeviceMonitor
// on every drag step. All three prefs persist in UserDefaults.

import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceMonitor: DeviceMonitor!

    // Menu items we need to update dynamically.
    private var statusMenuItem: NSMenuItem!
    private var velocityModeItem: NSMenuItem!
    private var linearModeItem: NSMenuItem!
    private var invertItem: NSMenuItem!
    private var gainLabel: NSTextField!
    private var gainSlider: NSSlider!

    // UserDefaults keys.
    private let kScrollMode       = "scrollMode"       // "velocity" | "linear"
    private let kLinearGainPct    = "linearGainPercent" // Int, 1..500
    private let kInvertDirection  = "invertDirection"  // Bool

    // Current settings, mirrored into DeviceMonitor.
    private var isLinearMode = false
    private var linearGainPercent = 100
    private var invertDirection = false

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

        loadSettings()

        deviceMonitor = DeviceMonitor()
        deviceMonitor.onConnectionChanged = { [weak self] _ in
            self?.updateStatusDisplay()
        }
        applySettingsToMonitor()

        // Build the menu bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dial.low", accessibilityDescription: "BoDial")
        }

        statusItem.menu = buildMenu()

        // Start device monitoring — seizes the dial and synthesizes
        // scroll events from its raw HID reports.
        deviceMonitor.start()

        updateStatusDisplay()
        log.notice("Running. Menu bar icon installed.")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // -- Status display --
        statusMenuItem = NSMenuItem(title: "Searching...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // -- Scrolling mode (radio group) --
        let modeHeader = NSMenuItem(title: "Scrolling mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        velocityModeItem = NSMenuItem(title: "Velocity acceleration", action: #selector(selectVelocityMode), keyEquivalent: "")
        velocityModeItem.target = self
        velocityModeItem.indentationLevel = 1
        menu.addItem(velocityModeItem)

        linearModeItem = NSMenuItem(title: "Linear", action: #selector(selectLinearMode), keyEquivalent: "")
        linearModeItem.target = self
        linearModeItem.indentationLevel = 1
        menu.addItem(linearModeItem)
        updateModeChecks()

        // -- Linear gain slider (NSView-hosted so drags live-update) --
        let sliderItem = NSMenuItem()
        sliderItem.view = makeGainSliderView()
        menu.addItem(sliderItem)

        menu.addItem(NSMenuItem.separator())

        // -- Invert direction toggle --
        invertItem = NSMenuItem(title: "Invert direction", action: #selector(toggleInvert), keyEquivalent: "")
        invertItem.target = self
        invertItem.state = invertDirection ? .on : .off
        menu.addItem(invertItem)

        menu.addItem(NSMenuItem.separator())

        // -- Quit --
        let quitItem = NSMenuItem(title: "Quit BoDial", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // A custom view for the slider row: label above, slider below,
    // matching the indent of surrounding menu items.
    private func makeGainSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let label = NSTextField(labelWithString: gainLabelText())
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.frame = NSRect(x: 20, y: 24, width: 200, height: 16)
        container.addSubview(label)
        gainLabel = label

        let slider = NSSlider(value: Double(linearGainPercent),
                              minValue: 1,
                              maxValue: 500,
                              target: self,
                              action: #selector(gainSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 20, y: 4, width: 200, height: 20)
        container.addSubview(slider)
        gainSlider = slider

        updateGainControlsEnabled()
        return container
    }

    private func gainLabelText() -> String {
        return "Linear gain: \(linearGainPercent)%"
    }

    private func updateGainControlsEnabled() {
        // Slider only matters in linear mode. Leave it visible either way
        // (hiding an NSMenuItem.view leaves dead space) but grayed when
        // velocity mode is active so it's obvious the value isn't applied.
        gainSlider?.isEnabled = isLinearMode
        gainLabel?.textColor = isLinearMode ? .labelColor : .disabledControlTextColor
    }

    private func updateModeChecks() {
        velocityModeItem.state = isLinearMode ? .off : .on
        linearModeItem.state = isLinearMode ? .on : .off
    }

    @objc private func selectVelocityMode() {
        setMode(linear: false)
    }

    @objc private func selectLinearMode() {
        setMode(linear: true)
    }

    private func setMode(linear: Bool) {
        if isLinearMode == linear { return }
        isLinearMode = linear
        updateModeChecks()
        updateGainControlsEnabled()
        deviceMonitor.setMode(linear ? .linear : .velocity)
        UserDefaults.standard.set(linear ? "linear" : "velocity", forKey: kScrollMode)
    }

    @objc private func toggleInvert() {
        invertDirection.toggle()
        invertItem.state = invertDirection ? .on : .off
        deviceMonitor.invertDirection = invertDirection
        UserDefaults.standard.set(invertDirection, forKey: kInvertDirection)
    }

    @objc private func gainSliderChanged(_ sender: NSSlider) {
        let pct = Int(sender.doubleValue.rounded())
        if pct == linearGainPercent { return }
        linearGainPercent = pct
        gainLabel.stringValue = gainLabelText()
        deviceMonitor.setLinearGain(Double(pct) / 100.0)
        UserDefaults.standard.set(pct, forKey: kLinearGainPct)
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        isLinearMode = (defaults.string(forKey: kScrollMode) == "linear")
        invertDirection = defaults.bool(forKey: kInvertDirection)
        // object(forKey:) so a fresh install stays at 100, not 0.
        if let stored = defaults.object(forKey: kLinearGainPct) as? Int {
            linearGainPercent = max(1, min(500, stored))
        } else {
            linearGainPercent = 100
        }
    }

    private func applySettingsToMonitor() {
        deviceMonitor.setMode(isLinearMode ? .linear : .velocity)
        deviceMonitor.setLinearGain(Double(linearGainPercent) / 100.0)
        deviceMonitor.invertDirection = invertDirection
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
