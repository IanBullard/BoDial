// ScrollCurve.swift — Velocity-based acceleration for raw HID tick counts.
//
// Each HID report feeds `scale(ticks:, now:)` which returns a fractional
// pixel delta. Slow input (≤ `threshold` ticks/sec) is passed through 1:1;
// faster input gets amplified by a power curve, capped at `maxMultiplier`.
//
// To tune feel: edit the stored-property defaults, or tweak whichever
// `ScrollCurve` instance the call site owns. To try a different curve
// shape entirely, replace the body of `multiplier(for:)`.

import Foundation
import CoreFoundation

struct ScrollCurve {
    enum Mode {
        case velocity
        case linear
    }

    // Scaling mode. Velocity (default) runs the full acceleration curve.
    // Linear returns `ticks * linearGain` with no velocity tracking.
    var mode: Mode = .velocity

    // Multiplier applied in linear mode. 1.0 = 1 tick per pixel (100%).
    // Range is clamped by the UI to 0.01..5.0 (1%..500%).
    var linearGain: Double = 1.0

    // Ticks/sec at or below this are treated as 1:1. Raising the threshold
    // widens the "slow = precise" zone; lowering it makes the curve kick
    // in sooner.
    var threshold: Double = 40.0

    // Curve steepness above threshold. 1.0 = linear, 2.0 = quadratic.
    // Higher values make a small speed increase produce a big amplification.
    var exponent: Double = 1.5

    // Hard ceiling on amplification so a fast spin doesn't teleport the view.
    var maxMultiplier: Double = 12.0

    // EMA weight on each new velocity sample. Higher = more responsive but
    // jitterier; lower = smoother but laggy. 0.3 is a reasonable starting
    // point for HID reports arriving every few milliseconds.
    var smoothing: Double = 0.3

    // If this long passes with no reports, the next report is treated as
    // fresh motion (EMA reset to zero). Prevents a stale "fast" velocity
    // from coloring the first tick of a new gesture.
    var idleResetSec: Double = 0.15

    private var smoothedVelocity: Double = 0
    private var lastReportTime: CFAbsoluteTime = 0

    // Returns a fractional pixel delta for this report's tick count.
    // The caller owns sub-pixel accumulation and rounding.
    mutating func scale(ticks: Int, now: CFAbsoluteTime) -> Double {
        if ticks == 0 { return 0 }

        if mode == .linear {
            return Double(ticks) * linearGain
        }

        let dt = now - lastReportTime
        lastReportTime = now

        if dt <= 0 || dt > idleResetSec {
            smoothedVelocity = 0
        }

        let instant = dt > 0 ? Double(abs(ticks)) / dt : 0
        smoothedVelocity = smoothing * instant + (1 - smoothing) * smoothedVelocity

        return Double(ticks) * multiplier(for: smoothedVelocity)
    }

    // Clear velocity state — call on device attach / transport switch so
    // stale timing from a previous session can't leak into the first tick.
    mutating func reset() {
        smoothedVelocity = 0
        lastReportTime = 0
    }

    // The curve. Replace the body to change feel.
    private func multiplier(for velocity: Double) -> Double {
        if velocity <= threshold { return 1.0 }
        let m = pow(velocity / threshold, exponent)
        return min(m, maxMultiplier)
    }
}
