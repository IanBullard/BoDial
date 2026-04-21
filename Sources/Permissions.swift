// Permissions.swift — TCC preflight for BoDial.
//
// BoDial needs one permission: Input Monitoring, so IOHIDManagerOpen can
// seize the dial and deliver HID reports. We check up front and present a
// consolidated alert if missing, so the user doesn't trip over the gate on
// first dial motion.

import Cocoa
import IOKit.hid
import os

struct PermissionStatus {
    let inputMonitoring: Bool
    var bothGranted: Bool { inputMonitoring }
}

enum Permissions {
    /// Check — and if necessary, prompt for — Input Monitoring.
    /// On first launch this triggers the system TCC prompt. On subsequent
    /// launches it just reports current grant state.
    static func check() -> PermissionStatus {
        // IOHIDRequestAccess: returns true if already granted. If not granted
        // and no prior decision, the system shows the Input Monitoring prompt
        // and returns false immediately (grant takes effect on next launch).
        let im = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log.notice("Permissions: InputMonitoring granted=\(im, privacy: .public)")
        return PermissionStatus(inputMonitoring: im)
    }

    /// Show an alert describing the missing Input Monitoring permission and
    /// offer to open the Settings pane. Caller is expected to terminate
    /// after this — TCC grants don't apply to the running process.
    static func presentMissingAlert(_ status: PermissionStatus) {
        // LSUIElement apps launched from Terminal aren't the active app, so
        // NSAlert.runModal() can be dismissed without the user ever seeing
        // it. Force activation first so the alert actually presents.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "BoDial needs permission to run"
        alert.informativeText = """
            BoDial needs Input Monitoring permission in System Settings › Privacy & Security.

            Grant it, then relaunch BoDial once. You should not need to launch it again after that.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
