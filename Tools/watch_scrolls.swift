#!/usr/bin/env swift
// Listen-only CGEventTap for scroll events. Prints every scroll event that
// reaches the session-tap point of the pipeline — i.e. what apps actually
// receive. Handy for verifying BoDial's output envelope and for comparing
// scroll behavior between devices.
//
// Requires Accessibility permission. First run will fail; add
// `build/watch_scrolls` to System Settings › Privacy & Security ›
// Accessibility, then run again.

import Foundation
import CoreGraphics

// Set after tapCreate so the @convention(c) callback can re-enable the
// tap if the OS disables it. Globals are the only shared state a C-ABI
// callback can reach without an UnsafeMutableRawPointer dance.
var installedTap: CFMachPort?

let scrollCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .scrollWheel:
        let py = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let px = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let fy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let ly = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let isCont = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let loc = event.location

        let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        let line = String(
            format: "[%@] SCROLL cont=%d phase=%d mom=%d  point=(%+.2f,%+.2f) fixed=(%+.2f,%+.2f) line=(%+d,%+d)  loc=(%.0f,%.0f)",
            ts, Int(isCont), Int(phase), Int(momentum),
            px, py, fx, fy,
            Int(lx), Int(ly),
            loc.x, loc.y
        )
        print(line)
        fflush(stdout)

    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        fputs("watch_scrolls: tap disabled (\(type.rawValue)), re-enabling\n", stderr)
        if let tap = installedTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: scrollCallback,
    userInfo: nil
) else {
    fputs("""
        watch_scrolls: CGEvent.tapCreate failed.
        Grant Accessibility to this binary:
          System Settings › Privacy & Security › Accessibility
          → add build/watch_scrolls (drag it in) and enable it.

        """, stderr)
    exit(1)
}
installedTap = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

fputs("watch_scrolls: listening at cgSessionEventTap. Ctrl+C to stop.\n", stderr)
CFRunLoopRun()
