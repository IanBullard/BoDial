// Permissions.swift — TCC preflight for BoDial.
//
// BoDial needs two separate permissions:
//   1. Input Monitoring — so IOHIDManagerOpen can deliver HID reports.
//   2. Accessibility    — so CGEvent.tapCreate on cghidEventTap can suppress
//                         the dial's native scroll events.
//
// Historically the app only surfaced (2), and only after failing at (1),
// which forced the user through multiple launch/grant/relaunch cycles.
// This module checks both up front, triggers the native prompts, and
// reports status so the app can exit cleanly with a single consolidated
// message when either is missing.

import Cocoa
import IOKit.hid
import os

struct PermissionStatus {
    let inputMonitoring: Bool
    let accessibility: Bool
    var bothGranted: Bool { inputMonitoring && accessibility }
}

enum Permissions {
    /// Check — and if necessary, prompt for — both required permissions.
    /// On first launch this will trigger the system TCC prompts. On
    /// subsequent launches it just reports current grant state.
    static func check() -> PermissionStatus {
        // IOHIDRequestAccess: returns true if already granted. If not granted
        // and no prior decision, the system shows the Input Monitoring prompt
        // and returns false immediately (grant takes effect on next launch).
        let im = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log.notice("Permissions: InputMonitoring granted=\(im, privacy: .public)")

        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt is
        // what actually registers the app with TCC — without this call, the
        // app never appears in System Settings › Accessibility, so there's
        // nothing for the user to toggle. The option also shows the system
        // prompt, which is fine: our own NSAlert follows and survives it
        // because applicationDidFinishLaunching sets activationPolicy to
        // .regular before presenting.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        log.notice("Permissions: Accessibility granted=\(ax, privacy: .public)")

        return PermissionStatus(inputMonitoring: im, accessibility: ax)
    }

    /// Show a single consolidated alert describing whichever permissions are
    /// still missing, offer to open the right Settings pane(s), then return.
    /// Caller is expected to terminate after this — TCC grants don't apply
    /// to the running process.
    static func presentMissingAlert(_ status: PermissionStatus) {
        var missing: [String] = []
        if !status.inputMonitoring { missing.append("Input Monitoring") }
        if !status.accessibility   { missing.append("Accessibility") }

        // LSUIElement apps launched from Terminal aren't the active app, so
        // NSAlert.runModal() can be dismissed without the user ever seeing
        // it. Force activation first so the alert actually presents.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "BoDial needs permission to run"
        alert.informativeText = """
            BoDial needs the following permission\(missing.count == 1 ? "" : "s") in System Settings › Privacy & Security:

            • \(missing.joined(separator: "\n• "))

            Grant \(missing.count == 1 ? "it" : "both"), then relaunch BoDial once. You should not need to launch it again after that.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open the most relevant pane. If both are missing we can only
            // open one directly; Input Monitoring first since it's the one
            // that blocks the device from being readable at all.
            let urlString: String
            if !status.inputMonitoring {
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
