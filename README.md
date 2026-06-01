# Acuity

> **Active.** Acuity provides persistent supersampled HiDPI for standard-density QHD external monitors. This is the use case BetterDisplay's free tier also covers, but BetterDisplay does not persist the chosen mode across reboot without keeping the app resident. Acuity remembers your chosen "looks like" size per display and re-applies it on reconnect and at login via a small LaunchAgent.

Native HiDPI scaling for external monitors on macOS. No SIP. No private entitlements. Open source.

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![MIT](https://img.shields.io/badge/license-MIT-green)

## Why

macOS enables HiDPI ("Retina") scaling based on a display's **pixel density, not its brand**. High-density panels — 4K/5K and anything near ~220 PPI, or where a clean 2× integer scale applies — get HiDPI scaled modes automatically, Apple-branded or not. But a standard-density external monitor, such as a 27" QHD (2560×1440, ~109 PPI), gets no useful HiDPI scaled modes by default: you're left with native 1× (sharp but small UI) or blurry non-integer scaling.

The fix is the long-established EDID-override technique: write a plist to `/Library/Displays/Contents/Resources/Overrides/` that macOS reads at boot to expose additional **supersampled** HiDPI modes (rendered at 2× and downsampled to the panel). No SIP disable, no kernel extensions, no private entitlements.

Acuity automates the override generation, switches modes live via public CoreGraphics APIs, and remembers your chosen mode so a LaunchAgent re-applies it on reconnect and at login. The menubar is resolution-focused; DDC/CI control for brightness, contrast, and input remains available as CLI commands (DDC is unreliable over Thunderbolt docks, see the DDC note below).

> **Sharpness ceiling.** HiDPI improves anti-aliasing but cannot exceed the panel's physical pixel density. On a ~109 PPI panel it's clearly smoother than blurry scaling, but it is not true Retina — that requires a denser panel (4K ≈ 163 PPI, 5K ≈ 218 PPI), which then needs no override at all. Acuity helps most on sub-Retina panels where you want larger-but-sharp UI.

## Quick install

```bash
# 1. Build and install the binary
./scripts/install.sh

# 2. Enable HiDPI for all connected external displays (requires sudo)
sudo acuity enable --all --preset all

# 3. Reboot to activate the new display modes
sudo reboot

# 4. Install the daemon so overrides re-apply automatically on reconnect
acuity install
```

## Commands

| Command | Description |
| --- | --- |
| `acuity list` | List connected external displays and HiDPI status |
| `acuity status` | Show override + current-mode status for each display |
| `acuity enable --all` | Write HiDPI override plists for all external displays (default: 2× preset) |
| `acuity enable --all --preset 2x` | 2× scaling (half-native, e.g. 1280×720 @2× on 2560×1440) |
| `acuity enable --all --preset 1.5x` | 1.5× scaling |
| `acuity enable --all --preset all` | Full resolution ladder |
| `acuity enable --display 0xVID:0xPID` | Enable for a specific display |
| `acuity disable --all` | Remove override plists |
| `acuity set-resolution --all --width W --height H` | Switch live to a HiDPI "looks like" size — no reboot, no sudo |
| `acuity set-resolution --all --width W --height H --no-hidpi` | Switch to the 1× (soft) variant — shows the difference HiDPI makes |
| `acuity set-resolution --list` | List available HiDPI "looks like" sizes with zoom % |
| `acuity brightness <0-100>` | Set brightness via DDC/CI (requires direct DP/USB-C — see below) |
| `acuity contrast <0-100>` | Set contrast via DDC/CI |
| `acuity input <source>` | Switch input (hdmi1, hdmi2, dp1, dp2, usbc) |
| `acuity install` | Install the LaunchAgent (menubar app, auto-restarts) |
| `acuity uninstall` | Remove the LaunchAgent |
| `acuity uninstall --clean` | Remove daemon and all override plists |

## Demo

```
$ acuity list

Connected external displays:

  1. Display 10ac:41da
     ID         : 0x10AC:0x41DA
     Native     : 2560×1440
     Connection : Unknown
     Status     : HiDPI ✓

$ acuity status

Display 10ac:41da [10ac:41da] — Unknown
  Resolution:  2560×1440 @ 144Hz
  HiDPI plist: ✓ installed
  Current mode: ✓ HiDPI active (1680×945 @2× @ 144Hz)
  DDC/CI:      ✗ not available   # display connected through a dock — see DDC notes
```

## How it works

macOS exposes HiDPI modes when it finds a matching override plist under `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>`. The plist contains a `scale-resolutions` array of binary-encoded logical resolutions.

Acuity generates these entries for standard scaled resolutions (2×, 1.5×, and a full ladder), writes them to the correct path, and sets the `DisplayResolutionEnabled` WindowServer default. On reboot, macOS picks up the new modes.

`acuity set-resolution` then switches between the unlocked modes at runtime using public CoreGraphics APIs (`CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration`) — no reboot, no sudo. Note this can only *select* modes that already exist; *creating* HiDPI modes still requires the override (or a reboot to pick up newly written ones).

The LaunchAgent runs the menubar app (`acuity start`) and uses `CGDisplayRegisterReconfigurationCallback` to re-apply the HiDPI mode when a known display reconnects — useful for docks and KVM switches.

## DDC/CI notes (read before expecting brightness control)

DDC/CI control uses the private `IOAVService` framework via `dlsym` (no entitlement required), **Apple Silicon only**. It has strict connection requirements:

- **Works:** a **direct DisplayPort or USB-C (DisplayPort Alt Mode)** connection from the Mac to the monitor.
- **Does NOT work:** through Thunderbolt/USB docks — they strip the DDC I2C channel (`IOServiceMatching("IOAVService")` returns 0 entries).
- **Unreliable:** the built-in HDMI port on Apple Silicon — it generally does not expose the DDC channel (also 0 IOAVService entries on tested hardware).

If `acuity status` shows `DDC/CI: ✗ not available`, check your connection path first. HiDPI scaling is unaffected by any of this — it works over any connection.

## Supported displays

Any external monitor with an EDID. Tested on:

- Dell S2721DGF (QHD 2560×1440, 27", ~109 PPI)

If your display is not recognized or produces unexpected results, open an issue with the output of `acuity list --json`.

## DDC features

- Brightness and contrast (VCP codes 0x10, 0x12)
- Input source switching (VCP code 0x60): HDMI 1/2, DisplayPort 1/2, USB-C
- Apple Silicon only; Intel Macs are not supported; requires a direct DP/USB-C connection (see DDC/CI notes)

## Contributing

1. Fork and clone the repo
2. `swift build` to build, `swift test` to run tests
3. Open a pull request with a description of what changed and why

Bug reports with `acuity list --json` output and macOS version are appreciated.

## License

MIT. See [LICENSE](LICENSE).
