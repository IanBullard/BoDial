# Scroll Event Path: BoDial vs scrolldial — a macOS walkthrough

## Context

You want to understand the macOS/Swift/HID plumbing before committing to
an architectural direction. You're fluent on Windows/Linux so this
document prioritizes grounding the vocabulary and mental models via
analogies there, then walks the scroll-event path through both tools.

---

## Part 1 — macOS concepts for Windows/Linux programmers

### 1.1 The framework stack

macOS layers a lot of frameworks. From lowest to highest, the ones
BoDial touches:

| Layer                | What it is                                                        | Analogy                                        |
|---------------------|-------------------------------------------------------------------|------------------------------------------------|
| XNU kernel          | Hybrid Mach + BSD kernel. VM, scheduling, syscalls, IOKit core    | Linux kernel, NT kernel                        |
| IOKit (kernel)      | C++ driver framework. Every driver is an object in a registry tree| Linux device tree (`/sys`), Windows device tree|
| Mach / libSystem    | Low-level primitives: threads, ports, malloc, syscall wrappers    | glibc + kernel IPC                             |
| IOKit (user)        | Userspace helpers to talk to the kernel IORegistry                | libudev + ioctl on `/dev/hidraw*`              |
| CoreFoundation (CF) | C library of common types, reference-counted                      | GLib types, or COM on Windows                  |
| Foundation          | Objective-C wrapper over CF + extras (NSDate, NSFileManager…)     | GLib/GObject                                   |
| Core Graphics       | 2D drawing **and the input event system** (CGEvent lives here)    | part of X server + DirectInput merged together |
| AppKit              | UI framework: windows, menus, views, NSEvent dispatch             | Gtk, Win32+MFC                                 |

The oddity for a Windows/Linux programmer: **input events live in the
graphics framework**. `CGEvent` and `CGEventTap` are in Core Graphics
for historical NeXT reasons. Events synthesized there are wrapped
into `NSEvent` by AppKit for delivery to windows.

### 1.2 IOKit and IOHIDManager

Think of IOKit as "the Linux device tree (`/sys`) plus udev plus
D-Bus," all kernel-provided. Drivers are C++ objects in an in-kernel
registry; userspace accesses them via Mach-port IPC.

**IOHIDManager** is a userspace library that wraps all this for HID
devices (mice, keyboards, dials, gamepads). It gives you:

- A **matching dictionary** — a CFDictionary describing which devices
  you want (VID/PID, usage page, etc). Analogous to a udev rule.
- **Callbacks on appear/disappear** — fired when a matching device
  enters/leaves the registry. Analogous to udev monitor events.
- **Open modes:**
  - `kIOHIDOptionsTypeNone` — non-exclusive. You receive input reports
    via callback; the OS HID driver keeps receiving them too and
    keeps generating CGEvents. Analog: `open("/dev/hidraw5", O_RDONLY)`.
  - `kIOHIDOptionsTypeSeizeDevice` — exclusive/seize. Only you see
    reports; the OS driver stops generating events. Analog:
    `ioctl(fd, EVIOCGRAB, 1)` on an evdev node, or `HIDD_*` exclusive
    open on Windows (which effectively doesn't exist — Windows doesn't
    cleanly let userspace grab a HID device away from the class driver).

**Input reports** are the raw HID report bytes, pushed to your
callback. The wire format (which bytes mean what) is defined by the
device's HID Report Descriptor. The dial uses:
```
Report ID 3 = scroll
  byte 0    = 0x03 (report ID)
  bytes 1-2 = signed 16-bit wheel ticks (little-endian)
  bytes 3-4 = signed 16-bit horizontal pan ticks
```

### 1.3 CFRunLoop — the main-thread event loop

Every macOS app's main thread has a `CFRunLoop`. Conceptually:

- **Linux analog:** glib's `GMainLoop`. Attach sources (fd, timer,
  signal), the loop dispatches callbacks.
- **Windows analog:** `GetMessage` / `DispatchMessage`, but
  generalized — CFRunLoop also handles timers, file descriptors, and
  Mach ports directly.

Key concepts:

- **Source** — anything that can wake the loop: a Mach port (for IPC,
  like from IOKit), a timer, a file descriptor, a custom callback.
- **Mode** — which sources are live. `.default` handles most things;
  `.modalPanel` runs while a sheet is up; `.common` is a pseudo-mode
  meaning "all standard modes."
- **Scheduling** — bind something to a runloop so its callbacks fire:
  `IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)`.

In BoDial, *everything* runs on the main thread: HID callbacks,
CGEventTap callbacks, timers, UI. No locking needed, but any blocking
call freezes the app.

### 1.4 CGEvent and CGEventTap

**CGEvent** is a CFType — an opaque, reference-counted C pointer.
Picture a `struct` with a type tag and a bag of fields. Fields are
accessed via typed enum keys:

```swift
event.getIntegerValueField(.scrollWheelEventDeltaAxis1)    // Int64
event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)// Double
event.location                                             // CGPoint
```

**CGEventTap** is a global hook into the event stream — macOS's
equivalent of **`SetWindowsHookEx(WH_MOUSE_LL, …)`** on Windows.
Linux has no real equivalent (closest is intercepting at libinput or
writing a compositor plugin).

```swift
CGEvent.tapCreate(
    tap: .cghidEventTap,               // placement (see below)
    place: .headInsertEventTap,        // position in chain at that placement
    options: .defaultTap,              // can modify events (vs .listenOnly)
    eventsOfInterest: mask,            // bitmap of event types
    callback: scrollCallback,          // C-ABI function pointer
    userInfo: context                  // void* passed through
)
```

Callback signature and return semantics:
```swift
(proxy, type, event, userInfo) -> Unmanaged<CGEvent>?
```
- Return `passUnretained(event)` → event continues downstream
  (possibly mutated in place).
- Return `nil` → **event is dropped.** No tap after you, no app, no
  anyone sees it.
- Return a different event → substitution (rare).

**Tap placements** form a pipeline:
```
device → cghidEventTap → (WindowServer annotates) → cgAnnotatedSessionEventTap → cgSessionEventTap → apps
```
- **cghidEventTap** — earliest, closest to the HID driver. Both tools
  use this.
- **cgSessionEventTap** — just before delivery to apps. Useful target
  for `CGEvent.post(tap:)` because posted events don't re-enter your
  HID tap.

Taps are **global** — they see events from every device and every app,
which is why they're TCC-gated.

macOS also has a watchdog: if your callback takes too long, the system
will fire `tapDisabledByTimeout` and drop your tap until you
re-enable it. (Windows does the same via the `LowLevelHooksTimeout`
registry value.) While disabled, events flow past you un-intercepted.

### 1.5 NSEvent and gesture phases (the window-capture mechanism)

When a CGEvent reaches an app, AppKit wraps it in `NSEvent` and
dispatches through the NSView tree. Most scroll fields map directly:

| CGEvent field                         | NSEvent property            |
|---------------------------------------|-----------------------------|
| scrollWheelEventPointDeltaAxis1/2     | scrollingDeltaY/X           |
| scrollWheelEventIsContinuous          | hasPreciseScrollingDeltas   |
| scrollWheelEventScrollPhase           | phase (NSEventPhase)        |
| scrollWheelEventMomentumPhase         | momentumPhase               |

**Phase lifecycle** (originates with trackpad gestures):
```
phase = .began      ← first touch of a gesture
phase = .changed (× N) ← ongoing motion
phase = .ended      ← lift-off
momentumPhase = .began/.changed/.ended ← system-emitted inertia afterward
```

**NSScrollView's gesture capture** is the kicker. When a scroll view
sees `phase=.began`, it marks itself the "gesture target" and all
subsequent `.changed` events route to it **regardless of where the
cursor moves**, until `.ended` arrives. This is what makes trackpad
scrolling feel right when your fingers drift off the scroll area
mid-gesture.

Windows and Linux have no equivalent:
- **Windows** always routes `WM_MOUSEWHEEL` to the window under the
  cursor at delivery time.
- **X11** routes to focused window or cursor window depending on
  configuration, no concept of "locked gesture target."

This is exactly what causes your "old window keeps scrolling" bug:
we emit `phase=.began` on the first dial tick of a burst, and our
150ms end-timer never fires during a continuous spin, so the lock
stays across window switches.

### 1.6 TCC — "Transparency, Consent, Control"

Apple's per-app permission framework. Grants are stored persistently
keyed by app identity (bundle ID + code signature hash), in a SQLite
database the system owns.

Two grants matter here:

| Grant                    | TCC class key                   | What it unlocks                          |
|--------------------------|---------------------------------|------------------------------------------|
| Accessibility            | `kTCCServiceAccessibility`      | Install CGEventTaps, drive UI automation |
| Input Monitoring         | `kTCCServiceListenEvent`        | `IOHIDManagerOpen`, read HID reports     |

Quirks to know:
- Grants are bound to the signed identity. Rebuild with a different
  identity → grant doesn't transfer. (Why BoDial uses a stable
  self-signed identity for dev builds.)
- Grants **don't apply retroactively** to the running process. Must
  relaunch after granting.
- `IOHIDRequestAccess` / `AXIsProcessTrustedWithOptions` both trigger
  the system prompt as a side effect the first time they're called.

### 1.7 Swift idioms in this code

A few patterns that may look alien coming from C/C++:

**`@convention(c)` callbacks** — function pointer ABI compatible
with C APIs. Global Swift functions have this by default:
```swift
private func scrollCallback(
    proxy: CGEventTapProxy, type: CGEventType,
    event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? { ... }
```

**`Unmanaged<T>`** — explicit refcount bridge for passing Swift
instances across C `void*` context parameters:
```swift
// Encode self into a void*:
let ctx = Unmanaged.passUnretained(self).toOpaque()
IOHIDManagerRegisterDeviceMatchingCallback(manager, cb, ctx)

// Decode inside the callback:
let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
```
`passUnretained`/`takeUnretainedValue` don't touch the refcount (you
must ensure the object outlives the callback). `passRetained`/
`takeRetainedValue` do.

**Toll-free CF bridging** — Swift collections auto-cast to CF types:
```swift
let matching = [kIOHIDVendorIDKey: 0xFEED, kIOHIDProductIDKey: 0xBEEF]
    as CFDictionary
```

**Unmanaged as a return type** — tap callbacks return
`Unmanaged<CGEvent>?`. `nil` drops the event; non-nil passes through.

---

## Part 2 — The macOS scroll pipeline (end to end)

Now the concrete wire from physical motion to app reaction:

```
[physical device]
    │  USB / Bluetooth transfers
    ▼
[IOKit HID driver: IOHIDFamily]                   ← Win: hidclass.sys
    │                                               Lin: hid-core / evdev
    │  raw HID report bytes (report ID + payload)
    │
    ├──► [our IOHIDManager's input-report callback]   — timestamp-only in BoDial
    │
    └──► [Core Graphics event generator]
           │  maps HID → CGEvent, applies driver
           │  tuning curve for PointDelta pixel value
           ▼
    ┌──────────────────────────────────────────┐
    │   Event-tap pipeline (in order):         │
    │                                          │
    │   1. cghidEventTap     ← BoDial, SmoothDial install here
    │   2. cgAnnotatedSessionEventTap
    │   3. cgSessionEventTap ← gesture-end events posted here
    │                                          │
    └──────────────────────────────────────────┘
           │
           ▼
[WindowServer: decides which app/window]      ← Win: DefWindowProc routing
           │                                    Lin: Wayland compositor / X server
           ▼
[AppKit: wraps CGEvent as NSEvent]            ← Win: WM_MOUSEWHEEL
           │                                    Lin: libinput pointer axis
           ▼
[NSScrollView.scrollWheel:]
    └─ If phase=.began: lock self as gesture target (until .ended)
```

### Key CGEvent fields for scroll events

| field                                     | type   | meaning                                   |
|-------------------------------------------|--------|-------------------------------------------|
| `scrollWheelEventDeltaAxis1/2`            | Int64  | Integer line count (notches)              |
| `scrollWheelEventFixedPtDeltaAxis1/2`     | Double | Legacy fixed-point line count             |
| `scrollWheelEventPointDeltaAxis1/2`       | Double | **Pixel delta.** Driver tuning baked in.  |
| `scrollWheelEventIsContinuous`            | Int64  | 0 = discrete wheel notch, 1 = gesture     |
| `scrollWheelEventScrollPhase`             | Int64  | 0, 1=Began, 2=Changed, 4=Ended            |
| `scrollWheelEventMomentumPhase`           | Int64  | 0, or Began/Changed/Ended of inertia      |

**The critical rule:** apps apply `PointDelta` pixel-accurately only
when **`isContinuous=1` AND `scrollPhase` follows a valid lifecycle**.
Without both, they fall back to the discrete-wheel code path and
line-snap (~16–19 px). This is why both tools must rewrite events
into the continuous-gesture shape.

---

## Part 3 — BoDial's event path

### Setup at app launch

1. `DeviceMonitor.start()` creates `IOHIDManager`, sets a VID/PID
   match dictionary, calls `IOHIDManagerOpen(.None)` (non-exclusive
   — needs Input Monitoring). The OS HID driver keeps running; we're
   just eavesdropping on reports.

2. `deviceConnected` registers `IOHIDDeviceRegisterInputReportCallback`.
   Callback body is one line: `lastReportTime = mach_absolute_time()`
   (plus a one-shot first-report byte dump for diagnostics).
   `mach_absolute_time()` is like Win's `QueryPerformanceCounter` /
   Linux's `clock_gettime(CLOCK_MONOTONIC_RAW)`.

3. `ScrollEventTap.start()` creates a `cghidEventTap` for
   `kCGEventScrollWheel` (head-insert, needs Accessibility).

### Per-event path — scroll from the dial

1. Dial rotates → USB/BT sends HID Report ID 3. IOKit delivers it.

2. Two things happen, both scheduled on the main runloop:
   - **(a)** Our input-report callback fires →
     `lastReportTime = mach_absolute_time()`.
   - **(b)** Core Graphics maps the report through the driver's
     per-device tuning curve, producing a CGEvent with PointDelta
     (~10–30× the raw tick count) and integer line fields populated.

3. The CGEvent enters the tap pipeline. Our `cghidEventTap` is first.

4. `scrollCallback` in `EventTap.swift` fires. Handles
   `tapDisabledByTimeout`/`tapDisabledByUserInput` by re-enabling,
   then calls `monitor.applyScaling(to: event)`.

5. `applyScaling` logic:
   ```
   read phase, momentum, isContinuous from event
   if any ≠ 0 → inertia branch:
     if recently reshaped (within 500ms) → return false (suppress; driver inertia tail)
     else → return true (pass through; real trackpad)
   else → raw wheel branch:
     if !recentlyReceivedReport() → return true (another mouse, pass through unmodified)
     read PointDelta + FixedPt (fallback: DeltaAxis tick count)
     pixelAccumY += source × scaleFactor     ← sub-pixel integrator
     emitY = pixelAccumY rounded toward zero
     pixelAccumY -= emitY                    ← carry fractional remainder
     gesturePhase = (inGesture && < 150ms since last) ? Changed : Began
     lastGestureEventTime = now; lastGestureLocation = event.location
     scheduleGestureEnd()    ← arms/resets 150ms DispatchSourceTimer
     mutate event in place:
       isContinuous = 1
       scrollPhase = Began or Changed
       momentumPhase = 0
       DeltaAxis / FixedPtDelta = 0
       PointDelta = emitY, emitX
     return true
   ```

   `recentlyReceivedReport()` compares `(now - lastReportTime)` (mach
   timebase-corrected) against `kAttributionWindowNs` (250ms). Fresh
   timestamp ⇒ event attributed to the dial.

6. Tap returns `passUnretained(event)` — mutated event continues past
   session tap, into WindowServer, into the target app.

7. AppKit wraps as NSEvent. NSScrollView sees `phase=.began`, **locks
   itself as the gesture target**. Subsequent `.changed` events go to
   it regardless of cursor position.

8. App scrolls by `PointDelta` pixels.

9. 150ms after the last tick, `scheduleGestureEnd`'s timer fires on
   the main queue. Constructs a fresh `CGEvent(scrollWheelEvent2Source:
   units: .pixel, ...)` with `phase=4`, posts via
   `.cgSessionEventTap` — **below our HID tap, so it doesn't re-enter
   `scrollCallback`**.

10. NSScrollView releases gesture capture. Cursor-current window
    becomes the target again.

### Per-event path — scroll from another wheel mouse

1. Other mouse's HID report arrives. Doesn't match our VID/PID →
   our input-report callback is not invoked. `lastReportTime` stays
   stale.

2. CG generates a CGEvent. Our tap fires.

3. `applyScaling`:
   - `phase=0, momentum=0, isContinuous=0` → raw wheel branch.
   - `recentlyReceivedReport()` returns false (timestamp is old).
   - Return true **without mutating**.

4. Event continues unmodified. App treats it as native discrete wheel.
   Other mouse behaves exactly as if BoDial weren't running.

### Per-event path — trackpad swipe

1. Trackpad sends touch data. CG synthesizes scroll CGEvents with
   `isContinuous=1`, phases populated, pixel deltas.

2. Our tap fires. `applyScaling`:
   - `phase ≠ 0` → inertia branch.
   - `(now - lastGestureEventTime) > 500ms` OR `lastGestureEventTime == 0`
     → return true (pass through untouched).
   - Else (user just finished spinning the dial and grabbed the
     trackpad within 500ms) → return false → **event dropped**.

3. Normal case: trackpad works as designed. Edge case: first trackpad
   event after a dial spin is eaten.

### Per-event path — driver inertia tail (important)

After a rapid wheel burst, the OS mouse driver synthesizes phase /
momentum events to simulate post-stop inertia — a feature for
regular wheel mice. These events carry full-force PointDelta and
have **no accompanying HID report** (the dial isn't actually moving).

1. Phase/momentum-decorated CGEvent arrives.
2. Tap fires. `applyScaling` inertia branch.
3. `lastGestureEventTime` was set by our last real reshape, < 500ms
   ago → return false → **dropped.**

This suppression is what prevents the 1% page-jump bug you hit earlier.

---

## Part 4 — SmoothDial's event path

Much shorter. No IOHIDManager, no device opening, no filtering.

### Setup
Create `cghidEventTap` for `kCGEventScrollWheel`. Done. File-level
`static` state (not a class): `inGesture`, `lastEventTime`,
`lastLocation`, `endTimer`.

### Per-event path — any scroll event, any device

1. CGEvent arrives. Tap fires.

2. Callback:
   ```
   read phase, momentum, isContinuous
   if any ≠ 0 → return passUnretained (pass through untouched — no distinction
                between trackpad and driver inertia)
   else → raw wheel:
     read PointDelta + FixedPt (tick fallback)
     outY *= sensitivity                   ← fractional Double, NO accumulator
     gesturePhase = (inGesture && < 150ms) ? Changed : Began
     scheduleGestureEnd()
     mutate event: same fields as BoDial
     return passUnretained(event)
   ```

3. 150ms idle → synthetic phase=Ended posted via `.cgSessionEventTap`.

Every non-continuous wheel event from any device on the machine
flows through this same code.

---

## Part 5 — Side-by-side diff

| stage                          | BoDial                                                             | SmoothDial                              |
|-------------------------------|---------------------------------------------------------------------|-----------------------------------------|
| Device detection              | IOHIDManager VID/PID match                                          | none                                    |
| HID open                      | yes (non-exclusive, timestamps only)                                | no                                      |
| Accessibility permission      | required                                                            | required                                |
| Input Monitoring permission   | required                                                            | not required                            |
| Event tap                     | `cghidEventTap`, head-insert                                        | same                                    |
| Device filter                 | `recentlyReceivedReport()` 250ms window                             | none                                    |
| Phase/momentum events         | suppress within 500ms of last reshape, else pass through            | always pass through                     |
| Source of motion              | `PointDelta + FixedPt`, tick fallback                               | same                                    |
| Sub-pixel accumulator         | yes                                                                 | no                                      |
| Output envelope               | isContinuous=1, Began/Changed, pixel delta only                     | same                                    |
| Gesture end                   | 150ms idle → phase=Ended via session tap                            | same                                    |
| Sensitivity anchor            | 100 = 1× driver's pixel delta (native)                              | same                                    |

---

## Part 6 — Your symptoms mapped to the pipeline

### "Old window keeps scrolling after switching focus"

**Not a filter issue.** It's step 7 of BoDial's dial path: AppKit's
NSScrollView gesture-capture. The `phase=.began` we emit locks scroll
delivery to the window under the cursor *at that moment*. Our Ended
timer only fires after 150ms of idle, so a continuous spin never
ends the gesture, and the lock survives window switches.

SmoothDial emits the identical envelope and therefore has the same
latent bug — your collaborator may simply not have hit it.

### "Sometimes no scroll events"

In rough probability order:

1. **Tap disabled by timeout/user-input** (`tapDisabledByTimeout`,
   `tapDisabledByUserInput`). macOS watchdog; re-enabled on the next
   call. Events during the disable window are lost. Shared with
   SmoothDial — same tap, same OS behavior. Windows' analog is the
   `LowLevelHooksTimeout` registry value.

2. **HID-callback / CGEvent race** — both callbacks are queued on
   the main runloop by IOKit from the same HID report. If the
   CGEvent callback is dispatched first, `lastReportTime` is still
   stale and `recentlyReceivedReport()` returns false. The event
   passes through **un-reshaped** — you'd see a single chunky
   line-scroll, not a missing event. Only affects the first tick of a
   burst after idle. BoDial-specific.

3. **Trackpad edge case** — grabbing the trackpad within 500ms of a
   dial spin drops the first trackpad event. Probably not what you're
   seeing with the dial alone.

(1) is shared. (2) and (3) are BoDial-specific consequences of having
filtering, but (2) results in a miss-reshape, not a miss-event.

---

## Part 7 — The architectural options, grounded in the primer

### Option A: keep everything, shorten gesture end
- Code change: `gestureTimeout = 0.15` → `0.03` (30 ms).
- What it fixes: window-focus capture (shorter lock, frequent re-grab).
- What it doesn't: tap-disable drops, HID/CGEvent race.
- Permission footprint: same (AX + Input Monitoring).

### Option B: keep architecture, end-on-cursor-movement
- Code change: compare current `event.location` to `lastGestureLocation`;
  if they differ by more than ~20 px, force-emit Ended immediately and
  Began on the next tick.
- What it fixes: window-focus capture (new window = cursor moved = gesture ends).
- What it doesn't: same as A.
- Permission footprint: same.

### Option C: seize the HID device
- Code change: `IOHIDManagerOpen` with `kIOHIDOptionsTypeSeizeDevice`,
  parse Report ID 3 in the input-report callback, construct CGEvents
  via `CGEvent(scrollWheelEvent2Source: units: .pixel, …)`, post via
  `.cgSessionEventTap`. **Delete `EventTap.swift` entirely.**
- What it fixes: all of A's wins + tap-disable drops (no tap) + race
  condition (we're the only source of events).
- Costs:
  - Lose driver tuning curve; have to invent our own scaling from raw
    ticks. Sensitivity semantics drift back to "pixels per tick × 100."
  - Dial dies if BoDial crashes (seized = no OS driver output).
  - Must correctly parse Report ID 3 for both USB and BLE transports
    (may differ).
- Permission footprint: same (both still needed — seize still requires
  Input Monitoring, and we could even drop Accessibility if we wanted
  since there's no tap).

### Option D: no change
- You wanted to understand first, decide later. Legitimate choice.
  The document now lets you explain the tradeoffs back to your
  collaborator in his vocabulary.

---

## Files referenced

- `/Users/ian/projects/ibullard/BoDial/Sources/DeviceMonitor.swift` —
  HID open, report-timestamp callback, `recentlyReceivedReport()`,
  `applyScaling()`, `scheduleGestureEnd()`.
- `/Users/ian/projects/ibullard/BoDial/Sources/EventTap.swift` —
  CGEventTap setup, callback that routes to `applyScaling`.
- `/Users/ian/projects/ibullard/BoDial/Sources/Permissions.swift` —
  TCC preflight for both permissions.
- `/Users/ian/projects/ibullard/BoDial/Sources/main.swift` +
  `AppDelegate.swift` — menu-bar UI, single-instance guard, lifecycle.
- `/Users/ian/projects/github/scrolldial/Sources/SmoothDial/SmoothDial.swift` —
  SmoothDial's entire implementation.

## Verification / next steps

Reference document, nothing to build.

When you're ready to change code:
- A or B: small surgical edits in `DeviceMonitor.swift`. Unit of work
  measured in minutes.
- C: substantial rewrite — delete `EventTap.swift`, add HID parsing
  and CGEvent construction in `DeviceMonitor`. Unit of work measured
  in hours, plus verification that the raw HID report format matches
  across USB and BLE transports.
