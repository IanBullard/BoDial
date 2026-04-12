#!/usr/bin/env swift
// Dump raw HID reports from the BoDial (Full Scroll Dial) via IOKit.

import Foundation
import IOKit
import IOKit.hid

let VID = 0xFEED
let PID = 0xBEEF

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching = [
    kIOHIDVendorIDKey: VID,
    kIOHIDProductIDKey: PID
] as CFDictionary

IOHIDManagerSetDeviceMatching(manager, matching)

let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard result == kIOReturnSuccess else {
    print("Failed to open HID manager: \(result)")
    exit(1)
}

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = deviceSet.first else {
    print("BoDial not found. Is it connected?")
    exit(1)
}

let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
let mfr = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? "Unknown"
print("Found: \(name) by \(mfr)")
print("Rotate the dial slowly. Press Ctrl+C to stop.")
print(String(repeating: "-", count: 60))

let callback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")

    // Note: reportBuffer includes report ID at byte 0, payload starts at byte 1
    if reportID == 3 && reportLength >= 5 {
        let wheel = Int16(data[1]) | (Int16(data[2]) << 8)
        let hpan  = Int16(data[3]) | (Int16(data[4]) << 8)
        print("SCROLL  wheel=\(String(format: "%+6d", wheel))  hpan=\(String(format: "%+6d", hpan))  raw=[\(hex)]")
    } else if reportID == 1 && reportLength >= 4 {
        let buttons = data[1]
        let x = Int8(bitPattern: data[2])
        let y = Int8(bitPattern: data[3])
        print("MOUSE   buttons=0x\(String(format: "%02x", buttons))  x=\(String(format: "%+4d", x))  y=\(String(format: "%+4d", y))  raw=[\(hex)]")
    } else {
        print("REPORT  id=\(reportID)  len=\(reportLength)  raw=[\(hex)]")
    }
}

var reportBuffer = [UInt8](repeating: 0, count: 64)
IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, callback, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

CFRunLoopRun()
