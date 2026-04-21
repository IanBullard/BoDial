// Permissions.swift — TCC preflight for BoDial.
//
// BoDial needs two permissions:
//   1. Input Monitoring — so IOHIDManagerOpen can seize the dial and
//      deliver HID reports.
//   2. Accessibility    — so CGEvent.post can inject synthesized scroll
//      events into the session event stream. On macOS 10.14+ any
//      synthetic input injection falls under Accessibility's purview.
//
// Both are checked up front so the user sees one consolidated alert
// instead of tripping over each gate in sequence across relaunches.
//
// TCC caches permission state per-process at launch — even after the user
// grants, the current process still can't use the new grant. To avoid
// "grant, then find and relaunch the app in Finder," the alert's primary
// action schedules a detached shell helper that sleeps 30s and then
// `open`s our bundle. The user grants at their own pace; BoDial
// reappears automatically.

import Cocoa
import IOKit.hid
import os

struct PermissionStatus {
    let inputMonitoring: Bool
    let accessibility: Bool
    var isGranted: Bool { inputMonitoring && accessibility }
}

enum Permissions {
    /// Check — and if necessary, prompt for — both required permissions.
    /// On first launch this triggers the system TCC prompts. On subsequent
    /// launches it just reports current grant state.
    static func check() -> PermissionStatus {
        // IOHIDRequestAccess returns true if already granted. If not granted
        // and no prior decision, the system shows the Input Monitoring prompt
        // and returns false immediately (grant takes effect on next launch).
        let im = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log.notice("Permissions: InputMonitoring granted=\(im, privacy: .public)")

        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt is
        // what actually registers the app with TCC — without this call the
        // app never appears in System Settings › Accessibility, so there's
        // nothing for the user to toggle. The option also shows the system
        // prompt.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        log.notice("Permissions: Accessibility granted=\(ax, privacy: .public)")

        return PermissionStatus(inputMonitoring: im, accessibility: ax)
    }

    /// Show an alert describing which permissions are missing, open the
    /// relevant Settings pane on user confirmation, and schedule a
    /// detached auto-relaunch. Caller is expected to terminate after this
    /// — TCC grants don't apply to the running process, so we need to
    /// exit cleanly and let the helper bring us back with fresh state.
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

            Click Open Settings to jump to the right pane. BoDial will quit and relaunch itself automatically once you've granted \(missing.count == 1 ? "it" : "them") (about 30 seconds).
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            openRelevantSettingsPane(status: status)
            if !scheduleRelaunch(after: relaunchDelaySeconds) {
                presentRelaunchFailedAlert()
            }
        }
    }

    private static func presentRelaunchFailedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't schedule auto-relaunch"
        alert.informativeText = """
            Grant the permission(s) in System Settings, then relaunch BoDial manually from Applications or wherever you installed it.
            """
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    // The most specific Settings URL for the first missing permission.
    // Accessibility is the fallback because there's only one direct link
    // we can open at a time.
    private static func openRelevantSettingsPane(status: PermissionStatus) {
        let urlString = !status.inputMonitoring
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // Delay before the helper relaunches us. Has to be long enough to
    // cover "user clicks Open Settings → scans the Privacy list → toggles
    // the switch" for two permissions in a row, short enough to feel
    // automatic. 30s is the result of that tradeoff.
    private static let relaunchDelaySeconds = 30

    // Spawn a detached /bin/sh helper that sleeps then `open`s our bundle.
    // The subprocess survives our exit (reparented to launchd), so the
    // caller should terminate immediately after this returns. Arguments
    // are passed positionally rather than interpolated to avoid any shell
    // quoting pitfalls in bundle paths — do not inline path/seconds into
    // the script body.
    //
    // Returns true if the helper launched, false if Process.run() failed.
    @discardableResult
    private static func scheduleRelaunch(after seconds: Int) -> Bool {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            #"sleep "$1"; open "$2""#,
            "sh",                  // $0 inside the script
            String(seconds),       // $1
            path,                  // $2
        ]
        do {
            try task.run()
            log.notice("Permissions: scheduled auto-relaunch in \(seconds, privacy: .public)s (pid \(task.processIdentifier, privacy: .public))")
            return true
        } catch {
            log.error("Permissions: scheduleRelaunch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
