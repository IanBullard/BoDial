# BoDial

macOS scroll sensitivity fix for the [Engineer Bo Full Scroll Dial](https://www.engineerbo.com/) — a high-resolution USB/Bluetooth rotary encoder.

The BoDial sends high-resolution scroll data (16-bit, up to 120x multiplier) that macOS interprets using its standard mouse scroll acceleration. This makes the dial unusably sensitive — a light touch scrolls several pages. BoDial fixes this by intercepting scroll events and scaling them to usable levels while preserving the dial's fine-grained resolution.

## Status

**Pre-production** — like the hardware itself. Works, solves the problem, ships as-is.

## How It Works

BoDial runs as a menu bar app (no Dock icon). It:

1. **Seizes** the dial via IOKit HID (USB vendor `0xFEED` / product `0xBEEF`) with `kIOHIDOptionsTypeSeizeDevice`. The OS HID driver stops generating scroll events for the dial — nothing else on the machine sees them.
2. **Parses** raw HID reports (Report ID 3: bytes 1-2 wheel, bytes 3-4 horizontal pan, both signed 16-bit little-endian).
3. **Scales** each tick by the sensitivity setting, carrying sub-pixel remainders across reports so slow turns at low sensitivity still eventually emit whole-pixel scroll events.
4. **Posts** synthesized `isContinuous=1` pixel-unit scroll CGEvents at the session tap point, routed to the window under the cursor at that moment. No gesture phase lifecycle, so no window-focus lock: scroll follows the mouse, always.
5. **Releases** the seize automatically when the app exits (clean or crash). The OS HID driver resumes and the dial reverts to stock behavior until BoDial is relaunched.

Other mice and trackpads are completely unaffected — BoDial only touches events it generates itself for the seized dial.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac (universal binary)
- Xcode Command Line Tools (`xcode-select --install`)
- Input Monitoring permission (System Settings > Privacy & Security > Input Monitoring) — required to seize the HID device

## Install

Download the latest `.zip` from [Releases](https://github.com/ibullard/BoDial/releases), unzip, and drag `BoDial.app` to your Applications folder.

On first launch:
1. macOS may warn about an unidentified developer — right-click the app and select **Open**
2. Grant Input Monitoring permission when prompted (or manually in System Settings), then relaunch once

## Building

```bash
git clone https://github.com/ibullard/BoDial.git
cd BoDial
make
```

This produces `build/BoDial.app`. To create a distributable zip:

```bash
make release
```

## Usage

- Launch `BoDial.app` — a dial icon appears in the menu bar
- Click the icon to see connection status and adjust sensitivity
- Sensitivity slider: **pixels per dial tick × 100**. 100% = 1 tick → 1 pixel. 1% = 1 tick → 0.01 pixel (accumulator emits 1 px every ~100 ticks).
- Your setting is saved automatically between launches

## Diagnostics

Two helper tools are included for debugging:

```bash
make dump_raw
build/dump_raw           # prints raw HID bytes from the dial
                         # — note: requires BoDial NOT running (seize conflict)

make watch_scrolls
build/watch_scrolls      # prints every scroll CGEvent reaching apps
                         # — requires Accessibility grant on the tool itself
```

Unified logs from the app:

```bash
log stream --predicate 'subsystem == "com.github.ibullard.bodial"'
```

## Known Limitations

- Because BoDial seizes the HID device, the dial depends on BoDial being running. If BoDial crashes or is force-killed, the dial reverts to the OS's native (too-sensitive) behavior until BoDial is relaunched — occasionally requiring an unplug/replug of the dial to force re-enumeration.
- Both USB and Bluetooth are tested.
- The VID/PID (`0xFEED`/`0xBEEF`) are pre-production placeholders and will likely change in the final hardware revision.

## License

[MIT](LICENSE)

## Acknowledgments

- **Engineer Bo** for creating the Full Scroll Dial hardware
- **Claude** (Anthropic) for collaborative development — architecture, IOKit/CGEvent integration, and iterative debugging
- This project is not affiliated with or endorsed by Engineer Bo
