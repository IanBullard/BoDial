// DeviceMonitor.swift — Reads raw HID reports from the BoDial and injects scaled scroll events.
//
// Opens the device (non-exclusively) to receive raw input reports. When
// rotation data arrives (Report ID 3), we scale it and post a synthetic
// CGEvent with a marker so the EventTap knows not to suppress it.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

let kBoDial_VID: Int = 0xFEED
let kBoDial_PID: Int = 0xBEEF

// Magic value set on our injected events so the EventTap can identify them.
let kBoDial_EventMarker: Int64 = 0xB0D1A1

// How many nanoseconds after a BoDial HID report do we attribute a scroll
// event to the BoDial. 10ms is generous — the real gap is typically <1ms.
let kAttributionWindowNs: UInt64 = 10_000_000

class DeviceMonitor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private var eventSource: CGEventSource?

    private(set) var isConnected = false

    // Mach absolute time of the last HID report from the BoDial.
    private(set) var lastReportTime: UInt64 = 0

    // Called when connection state changes (for UI updates).
    var onConnectionChanged: ((Bool) -> Void)?

    // Scale factor: 0.0 to 1.0. Read from UserDefaults each report.
    var scaleFactor: Double {
        let stored = UserDefaults.standard.integer(forKey: "scrollScale")
        let pct = stored > 0 ? stored : 5  // default 5%
        return Double(pct) / 100.0
    }

    init() {
        // Create a private event source for our injected events.
        eventSource = CGEventSource(stateID: .privateState)
        eventSource?.userData = kBoDial_EventMarker
    }

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching = [
            kIOHIDVendorIDKey: kBoDial_VID,
            kIOHIDProductIDKey: kBoDial_PID
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)

        let refSelf = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.deviceConnected(device)
        }, refSelf)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.deviceDisconnected(device)
        }, refSelf)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // Returns true if a BoDial HID report arrived within the attribution window.
    func recentlyReceivedReport() -> Bool {
        guard isConnected, lastReportTime > 0 else { return false }

        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)

        let now = mach_absolute_time()
        let elapsedTicks = now - lastReportTime
        let elapsedNs = elapsedTicks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)

        return elapsedNs < kAttributionWindowNs
    }

    private func deviceConnected(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        self.device = device
        self.isConnected = true

        // Register for raw input reports.
        let refSelf = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            { context, result, sender, type, reportID, report, length in
                let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.lastReportTime = mach_absolute_time()
                monitor.handleReport(reportID: reportID, report: report, length: length)
            },
            refSelf
        )

        print("[BoDial] Connected: \(name)")
        onConnectionChanged?(true)
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        print("[BoDial] Disconnected")
        self.device = nil
        self.isConnected = false
        self.lastReportTime = 0
        onConnectionChanged?(false)
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        // Report ID 3: Scroll data
        //   Byte 0: report ID (0x03)
        //   Bytes 1-2: wheel (16-bit signed, little-endian)
        //   Bytes 3-4: horizontal pan (16-bit signed, little-endian)
        guard reportID == 3, length >= 5 else { return }

        let rawWheel = Int16(report[1]) | (Int16(report[2]) << 8)
        let rawHPan  = Int16(report[3]) | (Int16(report[4]) << 8)

        guard rawWheel != 0 || rawHPan != 0 else { return }

        let scale = scaleFactor
        let scaledWheel = Double(rawWheel) * scale
        let scaledHPan  = Double(rawHPan) * scale

        injectScrollEvent(deltaY: scaledWheel, deltaX: scaledHPan)
    }

    private func injectScrollEvent(deltaY: Double, deltaX: Double) {
        // Create a pixel-precise continuous scroll event.
        // Using our private event source marks it with kBoDial_EventMarker
        // so the EventTap knows to pass it through.
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)

        event.post(tap: .cghidEventTap)
    }
}
