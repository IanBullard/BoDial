# BoDial

macOS companion app for the [Engineer Bo Full Scroll Dial](https://www.engineerbo.com/) — a high-resolution USB/Bluetooth rotary encoder.

BoDial takes exclusive ownership of the dial and delivers smooth per-pixel scroll events with velocity-based acceleration: slow turns stay pixel-precise (1 tick → 1 pixel), faster spins amplify automatically so long scrolls don't require winding forever. The OS's default interpretation of the dial as a standard mouse wheel makes it unusably sensitive (a light touch scrolls pages); BoDial replaces that with an adaptive curve tuned for the dial's resolution.

## Install

Download the latest `.zip` from [Releases](https://github.com/ibullard/BoDial/releases), unzip, and drag `BoDial.app` to Applications.

On first launch:

1. macOS may warn about an unidentified developer — right-click the app, select **Open**.
2. BoDial will ask for **Input Monitoring** and **Accessibility**. Click **Open Settings** in its alert to jump to the right pane, grant the permission, and BoDial will auto-relaunch within about 30 seconds with the new grant in effect — no need to hunt the app down in Finder. Input Monitoring lets BoDial read the dial; Accessibility lets it post synthesized scroll events (macOS classes any synthetic input injection as an accessibility feature).
3. On the second pass, BoDial will ask for the remaining permission the same way. **Note:** if System Settings is still open on the Input Monitoring pane from step 2, macOS may foreground that window without navigating to Accessibility — this is a known quirk of `x-apple.systempreferences:` URLs when Settings is already running. Just click **Privacy & Security → Accessibility** in the Settings sidebar and grant BoDial there.

## Use

Click the dial icon in the menu bar — it shows connection status and a Quit button. There's nothing to tune: scaling is automatic based on how fast you're spinning.

Other mice and trackpads are unaffected — BoDial only emits events for the dial itself.

## How it works

BoDial seizes the dial via `IOHIDManagerOpen(kIOHIDOptionsTypeSeizeDevice)`, which stops the OS HID driver from generating any scroll events for it. The app parses the dial's raw HID reports and maps each tick through a velocity-based acceleration curve: below ~40 ticks/sec output stays 1:1 (pixel-precise slow scrolling), above that the multiplier grows as `(velocity / threshold)^1.5` and caps at 12×. Velocity is smoothed with an exponential moving average so the scale doesn't twitch on per-report jitter, and sub-pixel remainders are carried across reports so even heavily attenuated input eventually crosses pixel boundaries. Output is posted as pixel-unit `CGEvent`s at the session tap point with `isContinuous=1` and no scroll-phase lifecycle — giving apps smooth per-pixel scrolling without the gesture-capture behavior that locks scroll delivery to a single window mid-spin.

When BoDial exits — cleanly or via crash — the Mach ports are released and the OS driver resumes. The dial reverts to its too-sensitive default until BoDial is relaunched.

## Build

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`). Produces a universal binary (Apple Silicon + Intel).

```bash
git clone https://github.com/ibullard/BoDial.git
cd BoDial
make                # build/BoDial.app (signed with local identity)
make release        # build/BoDial-$(VERSION).zip (Developer ID signed, hardened runtime)
```

`make` signs the bundle with a local identity (default: `BoDial`). On a fresh clone, override with ad-hoc signing:

```bash
make CODESIGN_IDENTITY=-
```

Ad-hoc works fine for running locally, but the signature changes every rebuild — macOS treats each build as a new app and re-prompts for TCC grants. For stable grants across rebuilds, create a one-off self-signed cert named `BoDial` in Keychain Access (**Keychain Access → Certificate Assistant → Create a Certificate**, identity type = Code Signing, self-signed) and the default just works.

`make release` expects a Developer ID Application certificate in your keychain. Override the identity via `DEVID_IDENTITY="Developer ID Application: Your Name (TEAMID)"` if yours is different.

## Diagnostics

- `make dump_raw && build/dump_raw` — print raw HID reports from the dial. BoDial must not be running (seize conflict).
- `make watch_scrolls && build/watch_scrolls` — print every scroll event reaching apps (listen-only session tap). Grant the tool Accessibility in System Settings on first run.
- `log stream --predicate 'subsystem == "com.github.ibullard.bodial"'` — live app logs.
- `scroll-test.html` — open in any browser to visually verify scrolling with a pseudo-live dial indicator.

## Known limitations

- BoDial must be running for the dial to work usefully; if it crashes, the dial reverts to the OS default until relaunch. After a force-quit, the dial may need an unplug/replug for the OS driver to re-enumerate cleanly.
- The VID/PID (`0xFEED`/`0xBEEF`) are pre-production placeholders; they will change in the final hardware revision.

## Credits

- **Engineer Bo** — the Full Scroll Dial hardware.
- **[callan101/scrolldial](https://github.com/callan101/scrolldial)** — Callan's SmoothDial work was the inspiration for the continuous-pixel approach; `scroll-test.html` is sourced from that repo.
- **Claude** (Anthropic) — collaborative development: IOKit/CGEvent integration, architecture iteration, and this README.

Not affiliated with or endorsed by Engineer Bo.

## License

[MIT](LICENSE)
