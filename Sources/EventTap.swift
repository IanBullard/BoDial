// EventTap.swift — Suppresses original BoDial scroll events.
//
// macOS generates scroll events from the BoDial's HID reports at a driver
// level we can't intercept. Instead, we suppress those events here and let
// DeviceMonitor inject replacement events with proper scaling.
//
// We identify BoDial-originated events using the DeviceMonitor's report
// timestamps — if a scroll event arrives within 10ms of a BoDial HID report,
// it came from the BoDial. Our own injected events carry a marker in
// eventSourceUserData so we pass them through.

import CoreGraphics
import Foundation

class ScrollEventTap {
    fileprivate var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var deviceMonitor: DeviceMonitor?

    init(deviceMonitor: DeviceMonitor) {
        self.deviceMonitor = deviceMonitor
    }

    func start() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)

        let context = TapContext(tap: self, monitor: deviceMonitor!)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: scrollCallback,
            userInfo: contextPtr
        ) else {
            print("[BoDial] ERROR: Failed to create event tap.")
            print("         Grant Accessibility permission in:")
            print("         System Settings > Privacy & Security > Accessibility")
            return false
        }

        self.machPort = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        print("[BoDial] Event tap installed.")
        return true
    }
}

private class TapContext {
    let tap: ScrollEventTap
    let monitor: DeviceMonitor
    init(tap: ScrollEventTap, monitor: DeviceMonitor) {
        self.tap = tap
        self.monitor = monitor
    }
}

private func scrollCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let info = userInfo {
            let context = Unmanaged<TapContext>.fromOpaque(info).takeUnretainedValue()
            if let port = context.tap.machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let info = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let context = Unmanaged<TapContext>.fromOpaque(info).takeUnretainedValue()

    // Pass through our own injected events (marked with kBoDial_EventMarker).
    let userData = event.getIntegerValueField(.eventSourceUserData)
    if userData == kBoDial_EventMarker {
        return Unmanaged.passUnretained(event)
    }

    // If the BoDial recently sent a HID report, this scroll event is from
    // the BoDial's OS driver. Suppress it — our replacement is already queued.
    if context.monitor.recentlyReceivedReport() {
        return nil  // Suppress the event
    }

    // Not from the BoDial — pass through (trackpad, mouse, etc.)
    return Unmanaged.passUnretained(event)
}
