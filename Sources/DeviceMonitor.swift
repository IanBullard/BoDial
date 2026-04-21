// DeviceMonitor.swift — Seizes the BoDial and synthesizes scroll events.
//
// Opens the device with kIOHIDOptionsTypeSeizeDevice, so the OS HID driver
// stops generating scroll CGEvents from it. We parse raw HID reports
// (Report ID 3: bytes 1-2 wheel, bytes 3-4 horizontal pan, both signed
// 16-bit little-endian), scale by the sensitivity factor with a sub-pixel
// accumulator, and post pixel-unit scroll CGEvents directly at the
// session tap point.
//
// When BoDial exits (clean or crash), the Mach ports are released and
// the OS driver resumes — the dial reverts to its stock behavior.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import os

let kBoDial_VID: Int = 0xFEED
let kBoDial_PID: Int = 0xBEEF

// Sensitivity UI + persistence. The slider and DeviceMonitor both read
// and write this key, so the range and default live in one place.
enum Sensitivity {
    static let defaultsKey = "scrollScale"
    static let min         = 1
    static let max         = 500
    static let defaultPct  = 100
}

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

    // One-shot diagnostic: log the first report we see so we can tell whether
    // e.g. BLE uses a different report ID / layout than USB. Then stay quiet.
    private var firstReportLogged = false

    // Sub-pixel accumulator. We scale raw HID tick counts by the sensitivity
    // factor and round toward zero for the emitted event, carrying the
    // fractional remainder across reports. Without this, low sensitivity
    // rounds every individual tick to zero and the dial feels dead until
    // the user spins fast enough that the scaled delta crosses 1 pixel.
    private var pixelAccumY: Double = 0
    private var pixelAccumX: Double = 0

    // Called when connection state changes (for UI updates).
    var onConnectionChanged: ((Bool) -> Void)?

    // Slider semantics: pixels per raw HID tick = scaleFactor. 100 means
    // 1 tick → 1 px (the 1:1 baseline). Below that is attenuation with
    // sub-pixel accumulation; above is amplification (e.g. 500 = 1 tick
    // → 5 px). Default assumes a first-time user with no stored value.
    var scaleFactor: Double {
        let stored = UserDefaults.standard.integer(forKey: Sensitivity.defaultsKey)
        let pct = stored > 0 ? stored : Sensitivity.defaultPct
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
        log.notice("DeviceMonitor.start: scheduled on runloop, opening (seize)...")

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
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

        logMatchingDevices(manager)
    }

    private func logMatchingDevices(_ manager: IOHIDManager) {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            log.notice("DeviceMonitor.start: IOHIDManagerCopyDevices returned nil")
            return
        }
        log.notice("DeviceMonitor.start: matching devices currently present: \(set.count, privacy: .public)")
        for d in set {
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
            let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
            let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? -1
            log.notice("  - \(name, privacy: .public) VID=0x\(String(vid, radix: 16), privacy: .public) PID=0x\(String(pid, radix: 16), privacy: .public)")
        }
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

        // Register a report callback on EVERY matching device. Only the
        // active device actually gets synthesized events; see handleReport.
        let refSelf = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            { context, result, sender, type, reportID, report, length in
                let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
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
            let connected = (device != nil)
            if connected != isConnected {
                isConnected = connected
                onConnectionChanged?(connected)
            }
            return
        }

        if device != nil {
            detachDevice()
        }

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
        self.device = device
        isConnected = true
        firstReportLogged = false  // re-log first report after a transport switch
        // Drop any residual sub-pixel remainder from the previous transport
        // so a switch doesn't emit a phantom pixel later.
        pixelAccumY = 0; pixelAccumX = 0
        onConnectionChanged?(true)
    }

    private func detachDevice() {
        if let d = device {
            log.notice("Detached: \(self.describe(d), privacy: .public)")
        }
        device = nil
        isConnected = false
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

    // Parse a HID input report from the active device and emit a scaled
    // pixel-unit scroll CGEvent. Only Report ID 3 carries scroll data.
    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        if !firstReportLogged {
            firstReportLogged = true
            let n = min(length, 16)
            var hex = ""
            for i in 0..<n { hex += String(format: "%02x ", report[i]) }
            log.notice("First report: id=\(reportID, privacy: .public) len=\(length, privacy: .public) bytes=\(hex, privacy: .public)")
        }

        guard reportID == 3, length >= 5 else { return }

        let wheelTicks = Int16(bitPattern: UInt16(report[1]) | (UInt16(report[2]) << 8))
        let hpanTicks  = Int16(bitPattern: UInt16(report[3]) | (UInt16(report[4]) << 8))

        let scale = scaleFactor
        pixelAccumY += Double(wheelTicks) * scale
        pixelAccumX += Double(hpanTicks) * scale

        let emitY = pixelAccumY.rounded(.towardZero)
        let emitX = pixelAccumX.rounded(.towardZero)
        pixelAccumY -= emitY
        pixelAccumX -= emitX

        // Sub-pixel tick — accumulator keeps the remainder for next time.
        if emitY == 0 && emitX == 0 {
            return
        }

        emitScrollEvent(pixelY: Int32(emitY), pixelX: Int32(emitX))
    }

    // Construct and post a pixel-unit scroll CGEvent at the current cursor.
    // isContinuous=1, phase=0, momentum=0 — no gesture lifecycle, so each
    // event routes fresh to the window under the mouse at that moment.
    private func emitScrollEvent(pixelY: Int32, pixelX: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: pixelY,
            wheel2: pixelX,
            wheel3: 0
        ) else {
            log.error("emitScrollEvent: CGEvent(scrollWheelEvent2Source:) returned nil")
            return
        }

        // Default event.location is (0,0). Probe the current cursor so the
        // event reaches the window under the mouse, not the top-left corner.
        if let probe = CGEvent(source: nil) {
            event.location = probe.location
        }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)

        event.post(tap: .cgSessionEventTap)
    }
}
