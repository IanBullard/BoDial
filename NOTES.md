# Collaboration notes — BoDial × scrolldial

Working notes for coordination between this repo (`ibullard/BoDial`) and
[`callan101/scrolldial`](https://github.com/callan101/scrolldial). Both
projects tackle the same problem — macOS driver treats the Engineer Bo
Full Scroll Dial as a discrete mouse wheel, snapping scrolls to line
height — and have converged on compatible-but-different approaches.

This file is a living summary of what each project does, what we borrowed
from scrolldial (as of 2026-04-21), and where the two implementations
still differ.

---

## What each project looks like

### BoDial (this repo)

Ships as a signed menu-bar `.app` with a UI, TCC preflight, device
connect/disconnect tracking, transport preference (USB > BLE), and a
persisted sensitivity setting.

Architecture:

- **`DeviceMonitor`** — opens the dial via `IOHIDManager`, registers an
  input-report callback on every matching device, and tracks a
  `lastReportTime` (mach time) for each HID report.
- **`ScrollEventTap`** — `cghidEventTap`, head-insert, scroll-wheel mask.
  For each scroll event, calls `deviceMonitor.recentlyReceivedReport()`;
  if a BoDial HID report landed in the last 10ms, the event is
  attributed to the dial and passed through `applyScaling(to:)`. Events
  outside the window pass through untouched (trackpad, other mice).
- **`AppDelegate`** — `NSStatusItem` menu bar UI with connection status,
  a 1–100% sensitivity slider, and (new) a "Continuous (pixel)
  scrolling" toggle.

Attribution strategy: **timing correlation**. No VID/PID matching
against the CGEvent (CGEvents don't carry that), no synthetic marker.
Just "did we see a HID report from the dial in the last 10ms."

### scrolldial (collaborator's repo)

Three small command-line tools, each demonstrating one idea:

- **`ScrollMonitor`** — subscribes to scroll events via
  [`CGEventSupervisor`](https://github.com/stephancasas/CGEventSupervisor)
  and prints them. Pure diagnostic.
- **`StripScrollLines`** — `cghidEventTap` that merges the legacy
  fixed-point delta into the point delta and zeroes fixed. Leaves
  integer line fields alone (per its comment: zeroing them "breaks many
  stacks").
- **`SmoothDial`** — the important one for our purposes. `cghidEventTap`
  that reshapes every discrete scroll-wheel event into a continuous /
  precise scroll gesture (the same envelope a trackpad produces). This
  is what gets apps to scroll per-pixel instead of snapping to line
  height.

No device filtering — `SmoothDial` reshapes **every** non-continuous
scroll event. Trackpad events already have `isContinuous = 1` and are
skipped. Other mice get reshaped too (intentional: "every wheel mouse
becomes smooth").

---

## The key idea we pulled from `SmoothDial`

macOS scroll events carry multiple coexisting representations:

| Field | Type | Meaning |
|---|---|---|
| `scrollWheelEventDeltaAxis1/2` | Int64 | Line count (discrete notches) |
| `scrollWheelEventFixedPtDeltaAxis1/2` | Double | Fixed-point line count (legacy) |
| `scrollWheelEventPointDeltaAxis1/2` | Double | Pixel delta |
| `scrollWheelEventIsContinuous` | Int64 | 0 = wheel, 1 = trackpad/gesture |
| `scrollWheelEventScrollPhase` | Int64 | 0, 1=Began, 2=Changed, 4=Ended |
| `scrollWheelEventMomentumPhase` | Int64 | 0 or momentum phase |

AppKit/UIKit scroll views **only honor the pixel delta** when the event
looks like a trackpad gesture. The recipe for that:

1. `isContinuous = 1`
2. `scrollPhase` is non-zero and follows a proper lifecycle
   (Began → Changed → Ended)
3. `momentumPhase = 0`
4. The integer and fixed-point line fields are zeroed
5. Only `PointDeltaAxis1/2` carries the scaled pixel delta

If any of those are wrong (especially #2), apps drop back to the
discrete-wheel path and snap to line height (~16–19px on a typical
display).

`SmoothDial` produces that gesture shape by:

- Tracking `inGesture` + `lastEventTime` + `lastLocation` in statics.
- On each incoming tick: set phase to Began (first tick of a burst) or
  Changed (subsequent), write the scaled pixel delta, zero the line
  fields, arm a 150ms one-shot.
- If 150ms passes with no new tick, the one-shot posts a synthetic
  Ended event (phase=4, zero deltas) via `.cgSessionEventTap`.

That's the whole trick. The rest is bookkeeping.

---

## What changed in BoDial

Changes made 2026-04-21, informed by `SmoothDial` and direct feedback
from its author.

**Round 1:** Adopted the continuous/pixel gesture envelope from
`SmoothDial`. Line mode removed — strictly worse at any setting.

**Round 2:** After the test page (`scroll-test.html`) showed the dial
"reads almost perfectly" through `wheel` events without any app
running, we realized BoDial's tick-count-based scaling was throwing
away the driver's own tuning. Switched to `SmoothDial`'s source of
motion (`PointDelta + FixedPtDelta`, tick fallback) so 100% = native
feel.

**Round 3 (scope correction):** We briefly dropped Input Monitoring by
removing `IOHIDManagerOpen` and gating the tap on
`isConnected` instead of HID-report timing — but that broadened scope
to "any wheel mouse while BoDial is plugged in." Since CGEvents don't
carry VID/PID, precise device filtering fundamentally requires reading
HID reports yourself. We reverted the attribution change: Input
Monitoring is back, HID-report timing attributes raw wheel events to
the dial, and only the dial's scrolls are reshaped.

### `Sources/DeviceMonitor.swift`

- Opens the HID device (non-exclusively) via `IOHIDManagerOpen` and
  registers an input-report callback on every matching device. The
  callback body only timestamps `lastReportTime` — the contents aren't
  parsed. One-shot first-report diagnostic kept for debugging
  transport differences (USB vs BLE).
- `recentlyReceivedReport()` returns true if `lastReportTime` is
  within `kAttributionWindowNs` (250ms) of now. Used by `applyScaling`
  as the raw-wheel gate.
- Gesture state: `inGesture`, `lastGestureEventTime`,
  `lastGestureLocation`, `gestureEndTimer`, `gestureTimeout = 0.15`,
  `inertiaSuppressionWindow = 0.5`.
- `applyScaling(to:)` decides per event:
  - **Phase/momentum/continuous event:** if we reshaped a wheel event
    within the last 500ms, it's the driver's inertia tail — suppress.
    Otherwise pass through (real trackpad).
  - **Raw wheel event with recent HID report:** reshape using the
    `SmoothDial` envelope — `isContinuous = 1`, `scrollPhase`
    Began→Changed, zeroed line + fixed fields, `PointDelta` carries
    the scaled pixel delta. Source of motion is `PointDelta +
    FixedPtDelta` (tick fallback when both are zero) — matches
    `SmoothDial` exactly.
  - **Raw wheel event with no recent HID report:** pass through
    unchanged (another mouse's scroll).
- `pixelAccumY/X` carries the sub-pixel remainder when scaling down,
  so slow spins at 1% still eventually emit whole pixels instead of
  rounding to zero. At 100% it's inactive.
- `scheduleGestureEnd()` posts a synthetic phase-4 Ended event via
  `.cgSessionEventTap` 150ms after the last real wheel tick.
- `attach()` / `detachDevice()` clear accumulator, cancel gesture
  timer, reset `lastReportTime` so transport switches don't leak state.
- Removed: `applyScalingLine`, `lineAccumY/X`, `continuousMode`,
  `kBoDial_EventMarker`.

### `Sources/EventTap.swift`

- Every scroll CGEvent routed unconditionally through `applyScaling`.
  Per-event logic (raw wheel vs phase/momentum, HID timing, inertia
  window) lives inside `applyScaling`; the tap just returns `nil` for
  `false` and the event for `true`.

### `Sources/Permissions.swift`, `Info.plist`

- Both Accessibility and Input Monitoring are preflight-checked and
  requested up front. Input Monitoring is required for the
  HID-report-timing attribution that keeps other mice untouched.

### `Sources/AppDelegate.swift`

- No mode toggle. The sensitivity slider is the only control.

### User-visible behavior

- Every install: continuous/pixel scrolling, dial-only.
- Slider semantics: **multiplier on the driver's native pixel delta.**
  100% = pass the driver's output through (native hardware feel),
  50% = half, 1% = a hundredth. Same anchor as `SmoothDial`'s
  "100 = 1×" convention.
- Other mice and trackpads are untouched — HID-report timing is the
  gate.


---

## Where the two codebases still differ

After convergence on the input-scaling path:

1. **Scope.** BoDial is a shipping signed `.app` with TCC preflight,
   connection UI (menu bar item, status line, sensitivity slider),
   transport preference (USB > BLE), and config persistence.
   `SmoothDial` is a single-file command-line tool run via
   `swift run SmoothDial 10`.

2. **Attribution.** BoDial uses HID-report-timing correlation (~250ms
   window) to reshape *only* the dial's scroll events; other mice and
   trackpads pass through untouched. `SmoothDial` reshapes every
   non-continuous wheel event from any device. BoDial therefore
   requires Input Monitoring; `SmoothDial` only needs Accessibility.

3. **Sensitivity cap.** BoDial's slider goes 1–100 (attenuation only).
   `SmoothDial`'s argv accepts >100 (200 = 2×). BoDial could easily
   match if we ever want amplification; we just haven't exposed it in
   the slider.

4. **Driver inertia suppression.** BoDial drops phase/momentum events
   that arrive within 500ms of our last reshaped wheel tick (driver's
   software inertia tail — otherwise at 1% it rides on the driver's
   full-force `PointDelta` and jumps pages). Trackpad gestures
   arriving outside that window pass through unchanged. `SmoothDial`
   lets all phase/momentum events through.

5. **Sub-pixel accumulation.** BoDial carries a sub-pixel remainder
   across events so slow dial motion at low sensitivity still
   eventually emits whole pixels. `SmoothDial` emits fractional
   `Double` point deltas directly. Low-impact difference since
   `SmoothDial` typically runs at 100% anyway.

6. **Logging.** BoDial uses `os.Logger` with a subsystem (Console.app
   friendly). `SmoothDial` prints to stdout. Fits each project's form
   factor.

---

## Open questions / possible next steps

- **Slider label.** Currently "Sensitivity: N%". Literal reading is
  "pixels per tick × 100". Leaving the label as-is for now — %-of-native
  reads fine — but we could relabel if users get confused about what
  100% means now.
- **Should we skip past the driver entirely?** BoDial currently reads
  the driver-computed integer tick count out of the CGEvent. If that
  turns out to be quantized or coalesced unhelpfully, we can parse the
  raw HID report directly (Report ID 3, bytes 1–2 = 16-bit signed
  tick count) and suppress the driver's CGEvent instead of scaling it.
  `handleReport` is already stubbed for this.
- **Momentum / inertia.** Neither project adds momentum. Trackpads
  generate their own post-gesture momentum phases; the dial is a
  physical flywheel so its own inertia carries the user. Probably
  don't add software momentum unless a user asks.
- **Sharing code.** If this stays two separate binaries we're fine.
  If we end up wanting one tool, factoring the gesture shaper into a
  small Swift package that both could depend on would be clean.
