# BoDial

macOS scroll sensitivity fix for the [Engineer Bo Full Scroll Dial](https://www.engineerbo.com/) — a high-resolution USB/Bluetooth rotary encoder.

The BoDial sends high-resolution scroll data (16-bit, up to 120x multiplier) that macOS interprets using its standard mouse scroll acceleration. This makes the dial unusably sensitive — a light touch scrolls several pages. BoDial fixes this by intercepting scroll events and scaling them to usable levels while preserving the dial's fine-grained resolution.

## Status

**Pre-production** — like the hardware itself. Works, solves the problem, ships as-is.

## How It Works

BoDial runs as a menu bar app (no Dock icon). It:

1. **Monitors** for the dial via IOKit HID (USB vendor `0xFEED` / product `0xBEEF`)
2. **Reads** raw HID reports directly from the device to get unprocessed rotation data
3. **Injects** new scroll events scaled to a configurable percentage, marked with an internal tag
4. **Suppresses** the original (too-sensitive) scroll events via a CGEventTap, using timing correlation between HID reports and CGEvents to identify BoDial-originated events
5. **Passes through** all non-BoDial scroll events untouched (trackpad, mouse, etc.)

Why not just modify the original events? macOS recalculates scroll values from the underlying HID data at the driver level, ignoring modifications made via CGEventTap. The only reliable approach is to suppress the originals and inject replacements.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac (universal binary)
- Xcode Command Line Tools (`xcode-select --install`)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)

## Install

Download the latest `.zip` from [Releases](https://github.com/ibullard/BoDial/releases), unzip, and drag `BoDial.app` to your Applications folder.

On first launch:
1. macOS may warn about an unidentified developer — right-click the app and select **Open**
2. Grant Accessibility permission when prompted (or manually in System Settings)

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

### Code signing

BoDial requires Accessibility and Input Monitoring permissions, which are managed by macOS's TCC (Transparency, Consent, and Control) subsystem. TCC identifies apps by their code signature — without one, it has nothing to match a permission grant against. An unsigned `.app` will appear in System Settings → Privacy & Security, and you can toggle the permission on, but it never actually takes effect: the app will keep prompting on every launch.

The Makefile signs the app as part of every build (the build will fail if the signing identity is missing). It defaults to a self-signed certificate named `BoDial`. Create it once in Keychain Access:

1. Open **Keychain Access** → **Certificate Assistant** → **Create a Certificate…**
2. Name: `BoDial`, Identity Type: **Self-Signed Root**, Certificate Type: **Code Signing**
3. Click **Create**

After that, `make` will sign the app automatically. Using a stable named certificate (rather than ad-hoc signing with `make CODESIGN_IDENTITY="-"`) keeps the signature consistent across rebuilds, so TCC continues to recognize the app and you won't have to re-grant permissions each time.

## Usage

- Launch `BoDial.app` — a dial icon appears in the menu bar
- Click the icon to see connection status and adjust sensitivity
- Sensitivity slider: **1%** (barely moves) to **100%** (full macOS default)
- Default: **5%** — a good starting point for light touch
- Your setting is saved automatically between launches

## Diagnostics

A raw HID report dumper is included for debugging:

```bash
make dump_raw
build/dump_raw
```

This prints the raw scroll values the dial sends, useful for verifying the hardware is working.

## Known Limitations

- Device filtering uses timing heuristics. In rare cases (two devices scrolling simultaneously within 10ms), a non-BoDial scroll event could be incorrectly suppressed.
- Only the USB interface is tested. Bluetooth may use different VID/PID values.
- The VID/PID (`0xFEED`/`0xBEEF`) are pre-production placeholders and will likely change in the final hardware revision.

## License

[MIT](LICENSE)

## Acknowledgments

- **Engineer Bo** for creating the Full Scroll Dial hardware
- **Claude** (Anthropic) for collaborative development — architecture, IOKit/CGEvent integration, and iterative debugging
- This project is not affiliated with or endorsed by Engineer Bo
