// DeviceMonitor.swift — Reads raw HID reports from the BoDial and injects scaled scroll events.
//
// Opens the device (non-exclusively) to receive raw input reports. When
// rotation data arrives (Report ID 3), we scale it and post a synthetic
// CGEvent with a marker so the EventTap knows not to suppress it.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import os

let kBoDial_VID: Int = 0xFEED
let kBoDial_PID: Int = 0xBEEF

// Magic value set on our injected events so the EventTap can identify them.
let kBoDial_EventMarker: Int64 = 0xB0D1A1

// How many nanoseconds after a BoDial HID report do we attribute a scroll
// event to the BoDial. 10ms is generous — the real gap is typically <1ms.
let kAttributionWindowNs: UInt64 = 10_000_000

class DeviceMonitor {
    private var manager: IOHIDManager?
    // Currently active device (the one we're listening to). Only one at a
    // time — see `pickPreferred()` for the selection rule.
    private var device: IOHIDDevice?
    // All matching devices the HID manager has told us about, keyed by
    // registry entry ID (stable across the device's lifetime). We track
    // everything so we can switch between transports as they come and go.
    private var knownDevices: [UInt64: IOHIDDevice] = [:]
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    private(set) var isConnected = false

    // Mach absolute time of the last HID report from the BoDial.
    private(set) var lastReportTime: UInt64 = 0

    // One-shot diagnostic: log the first report we see so we can tell whether
    // e.g. BLE uses a different report ID / layout than USB. Then stay quiet.
    private var firstReportLogged = false

    // Fractional accumulators used when scaling attributed scroll events in
    // the tap. At low sensitivity the scaled delta can be sub-unit; rather
    // than dropping it, we carry the remainder across events so small dial
    // motions still eventually produce a whole-pixel/line of scroll.
    private var pixelAccumY: Double = 0
    private var pixelAccumX: Double = 0
    private var lineAccumY: Double = 0
    private var lineAccumX: Double = 0

    // Called when connection state changes (for UI updates).
    var onConnectionChanged: ((Bool) -> Void)?

    // Slider semantics: 100 means "pass the device's own events through
    // unchanged" (×1.0), 1 means "a hundredth of what the device would do"
    // (×0.01). No base multiplier — at 100% the user wants the dial's
    // native feel, which the OS driver has already dialed in for us.
    var scaleFactor: Double {
        let stored = UserDefaults.standard.integer(forKey: "scrollScale")
        let pct = stored > 0 ? stored : 5
        return Double(pct) / 100.0
    }

    init() { }

    func start() {
        log.notice("DeviceMonitor.start: creating HID manager")
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching = [
            kIOHIDVendorIDKey: kBoDial_VID,
            kIOHIDProductIDKey: kBoDial_PID
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)
        log.notice("DeviceMonitor.start: matching VID=0x\(String(kBoDial_VID, radix: 16), privacy: .public) PID=0x\(String(kBoDial_PID, radix: 16), privacy: .public)")

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
        log.notice("DeviceMonitor.start: scheduled on runloop, opening...")

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let hex = String(format: "0x%08x", UInt32(bitPattern: openResult))
        if openResult == kIOReturnSuccess {
            log.notice("DeviceMonitor.start: IOHIDManagerOpen OK (\(hex, privacy: .public))")
        } else {
            let hint: String
            switch openResult {
            case kIOReturnNotPermitted:
                hint = "kIOReturnNotPermitted — Input Monitoring TCC grant is missing for THIS binary (path+signature). Remove BoDial from System Settings › Privacy & Security › Input Monitoring, relaunch, re-grant."
            case kIOReturnExclusiveAccess:
                hint = "kIOReturnExclusiveAccess — another process has the device open exclusively."
            case kIOReturnNoDevice:
                hint = "kIOReturnNoDevice — no matching device present (matching is async, usually benign)."
            default:
                hint = "unknown IOReturn code"
            }
            log.error("DeviceMonitor.start: IOHIDManagerOpen FAILED (\(hex, privacy: .public)): \(hint, privacy: .public)")
        }

        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            log.notice("DeviceMonitor.start: matching devices currently present: \(set.count, privacy: .public)")
            for d in set {
                let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
                let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
                let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? -1
                log.notice("  - \(name, privacy: .public) VID=0x\(String(vid, radix: 16), privacy: .public) PID=0x\(String(pid, radix: 16), privacy: .public)")
            }
        } else {
            log.notice("DeviceMonitor.start: IOHIDManagerCopyDevices returned nil")
        }
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

    // Transport preference: higher wins. USB > BLE > anything else.
    // Used by pickPreferred() to choose which matching device to listen to
    // when more than one is present (e.g. the dial paired over BLE *and*
    // plugged in over USB — then USB wins).
    private func transportRank(_ device: IOHIDDevice) -> Int {
        let t = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        switch t {
        case "USB":                   return 2
        case "Bluetooth Low Energy",
             "Bluetooth":             return 1
        default:                      return 0
        }
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        // Stable per-device ID — survives the device being the same physical
        // thing across callbacks. Service is a mach port; its registry entry
        // ID is the right identity key.
        let service = IOHIDDeviceGetService(device)
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    private func describe(_ device: IOHIDDevice) -> String {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        return "\(name) [\(transport)]"
    }

    private func deviceConnected(_ device: IOHIDDevice) {
        let id = registryID(device)
        knownDevices[id] = device
        log.notice("Device appeared: \(self.describe(device), privacy: .public) (known=\(self.knownDevices.count, privacy: .public))")

        // Register a report callback on EVERY matching device, not just the
        // active one. Reports from inactive transports still generate scroll
        // events in the OS; we need `lastReportTime` to move forward when
        // any of them fire so the EventTap suppresses those originals too.
        // Only the active device's reports produce our scaled replacement
        // (see handleReport gating below).
        let refSelf = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            { context, result, sender, type, reportID, report, length in
                let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.lastReportTime = mach_absolute_time()

                // Only inject for reports from the active device.
                guard let sender = sender else { return }
                let senderDev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                if senderDev === monitor.device {
                    monitor.handleReport(reportID: reportID, report: report, length: length)
                }
            },
            refSelf
        )

        pickPreferred()
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        let id = registryID(device)
        knownDevices.removeValue(forKey: id)
        log.notice("Device disappeared: \(self.describe(device), privacy: .public) (remaining=\(self.knownDevices.count, privacy: .public))")
        pickPreferred()
    }

    // Choose the best available device by transport rank, and make it the
    // active one. If the currently active device is already the best, this
    // is a no-op. Otherwise we detach the old one and attach the new.
    private func pickPreferred() {
        let best = knownDevices.values.max(by: { transportRank($0) < transportRank($1) })

        if best === device {
            // No change in selection — but update connected state in case
            // `device` is nil now (e.g. last device just disappeared).
            let connected = (device != nil)
            if connected != isConnected {
                isConnected = connected
                onConnectionChanged?(connected)
            }
            return
        }

        // Detach whatever we had.
        if device != nil {
            detachDevice()
        }

        // Attach the new best, if any.
        if let next = best {
            log.notice("Selecting device: \(self.describe(next), privacy: .public)")
            attach(next)
        } else {
            log.notice("No device available")
            isConnected = false
            onConnectionChanged?(false)
        }
    }

    private func attach(_ device: IOHIDDevice) {
        // Report callback was already installed in deviceConnected for every
        // known device. Making a device "active" is just a state flip — the
        // callback itself gates inject-vs-just-timestamp on `device ===`.
        self.device = device
        isConnected = true
        firstReportLogged = false  // re-log first report after a transport switch
        // Drop any residual fractional line-delta from the previous transport
        // so a switch doesn't produce a phantom line-tick later. Pixel
        // accumulator is cleared on every event already.
        lineAccumY = 0; lineAccumX = 0
        onConnectionChanged?(true)
    }

    private func detachDevice() {
        // Note: we deliberately do NOT unregister the input-report callback
        // here. Inactive devices must keep calling us back so lastReportTime
        // advances when the OS generates a scroll event from their reports,
        // letting the EventTap suppress those too. The callback gates on
        // `device ===` to decide whether to inject.
        if let d = device {
            log.notice("Detached: \(self.describe(d), privacy: .public)")
        }
        device = nil
        isConnected = false
        lastReportTime = 0
    }

    func stop() {
        guard manager != nil else {
            log.notice("DeviceMonitor.stop: already stopped")
            return
        }
        log.notice("DeviceMonitor.stop: detaching and closing HID manager")
        detachDevice()
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        log.notice("DeviceMonitor.stop: HID manager closed")
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        if !firstReportLogged {
            firstReportLogged = true
            let n = min(length, 16)
            var hex = ""
            for i in 0..<n { hex += String(format: "%02x ", report[i]) }
            log.notice("First report: id=\(reportID, privacy: .public) len=\(length, privacy: .public) bytes=\(hex, privacy: .public)")
        }

        // Report ID 3: Scroll data
        //   Byte 0: report ID (0x03)
        //   Bytes 1-2: wheel (16-bit signed, little-endian)
        //   Bytes 3-4: horizontal pan (16-bit signed, little-endian)
        guard reportID == 3, length >= 5 else { return }

        // Scaling is applied in the EventTap via applyScaling(to:) — this
        // function now only exists for the first-report diagnostic above.
        // We intentionally don't parse/inject anything here; the OS driver
        // has already produced a perfectly good scroll event that will flow
        // through the tap for scaling.
    }

    // Called from the event-tap callback for scroll events attributable to
    // the dial. Multiplies pixel and line deltas by the current scale
    // factor, carrying fractional remainders across events so low
    // sensitivities still produce occasional whole-unit scroll.
    //
    // Returns the event argument unchanged (for convenience at the call
    // site); mutation is in-place via the CGEvent field setters.
    func applyScaling(to event: CGEvent) {
        let scale = scaleFactor
        if scale == 1.0 {
            // 100%: pass-through. Preserve the device's own feel exactly.
            return
        }

        let rawPixelY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let rawPixelX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let rawLineY  = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let rawLineX  = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)

        pixelAccumY += rawPixelY * scale
        pixelAccumX += rawPixelX * scale
        lineAccumY  += Double(rawLineY) * scale
        lineAccumX  += Double(rawLineX) * scale

        // Pixel fields are Doubles, so we can emit the full scaled value and
        // keep zero remainder. Line fields are integers — truncate toward
        // zero and carry the fractional part into the next event.
        let emitLineY = lineAccumY.rounded(.towardZero)
        let emitLineX = lineAccumX.rounded(.towardZero)
        lineAccumY -= emitLineY
        lineAccumX -= emitLineX

        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pixelAccumY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: pixelAccumX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pixelAccumY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: pixelAccumX)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(emitLineY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(emitLineX))

        // Pixels are doubles so there's no rounding loss; clear the pixel
        // accumulator after emitting.
        pixelAccumY = 0
        pixelAccumX = 0
    }
}
