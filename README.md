# Acuity

Native HiDPI scaling for external monitors on macOS. No SIP. No private entitlements. Open source.

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![MIT](https://img.shields.io/badge/license-MIT-green)

## Why

macOS restricts HiDPI ("Retina") scaling to Apple-branded displays. External monitors — even high-DPI panels — render at 1× scaling by default, making text and UI elements look sharp on the native framebuffer but blurry when the display's own upscaling kicks in.

The fix: write an EDID override plist to `/Library/Displays/Contents/Resources/Overrides/`. macOS reads these at boot to expose additional scaled resolution modes. No SIP disable. No kernel extensions. No private entitlements.

Acuity automates the override generation, handles display reconnection via a lightweight LaunchAgent daemon, and provides DDC/CI control for brightness, contrast, and input switching.

## Quick install

```bash
# 1. Build and install the binary
./scripts/install.sh

# 2. Enable HiDPI for all connected external displays (requires sudo)
sudo acuity enable --all

# 3. Reboot to activate the new display modes
sudo reboot

# 4. Install the daemon so overrides re-apply automatically on reconnect
acuity install
```

## Commands

| Command | Description |
| --- | --- |
| `acuity list` | List connected external displays and HiDPI status |
| `acuity status` | Show override status for each display |
| `acuity enable --all` | Write HiDPI override plists for all external displays (default: 2× preset) |
| `acuity enable --all --preset 2x` | 2× scaling (half-native, e.g. 960×540 @2× on 1920×1080) |
| `acuity enable --all --preset 1.5x` | 1.5× scaling |
| `acuity enable --all --preset all` | Full resolution ladder |
| `acuity enable --display 0xVID:0xPID` | Enable for a specific display |
| `acuity disable --all` | Remove override plists |
| `acuity brightness <0-100>` | Set brightness via DDC/CI |
| `acuity contrast <0-100>` | Set contrast via DDC/CI |
| `acuity input <source>` | Switch input (hdmi1, hdmi2, dp1, dp2, usbc) |
| `acuity install` | Install the LaunchAgent daemon |
| `acuity uninstall` | Remove the LaunchAgent daemon |
| `acuity uninstall --clean` | Remove daemon and all override plists |

## Demo

```
$ acuity list

Connected external displays:

  1. Display 10ac:41da
     ID         : 0x10AC:0x41DA
     Native     : 1920×1080
     Connection : Unknown
     Status     : HiDPI ✓

$ acuity status

Display 10ac:41da [10ac:41da] — Unknown
  Resolution:  1920×1080 @ 144Hz
  HiDPI plist: ✓ installed
  Current mode: ✓ HiDPI active (960×540 @2× @ 144Hz)
  DDC/CI:      ✗ not available
```

## How it works

macOS exposes HiDPI modes when it finds a matching override plist under `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>`. The plist contains a `scale-resolutions` array of binary-encoded logical resolutions.

Acuity generates these entries for standard scaled resolutions (2×, 1.5×, and a full ladder), writes them to the correct path, and sets the `DisplayResolutionEnabled` WindowServer default. On reboot, macOS picks up the new modes.

The daemon (`acuity daemon`) uses `CGDisplayRegisterReconfigurationCallback` to watch for display connection events and re-applies the HiDPI mode automatically when a known display reconnects — useful for docking stations and KVM switches.

DDC/CI control uses the private `IOAVService` framework, accessed via `dlsym` (no entitlement required). Currently supported on Apple Silicon Macs.

## Supported displays

Any external monitor with an EDID. Tested on:

- Dell S2721DGF (QHD, 27")

If your display is not recognized or produces unexpected results, open an issue with the output of `acuity list --json`.

## DDC features

- Brightness and contrast (VCP codes 0x10, 0x12)
- Input source switching (VCP code 0x60): HDMI 1/2, DisplayPort 1/2, USB-C
- Apple Silicon required; Intel Macs are not supported

## Contributing

1. Fork and clone the repo
2. `swift build` to build, `swift test` to run tests
3. Open a pull request with a description of what changed and why

Bug reports with `acuity list --json` output and macOS version are appreciated.

## License

MIT. See [LICENSE](LICENSE).
