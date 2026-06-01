# Gotchas — Acuity

Repo-specific pitfalls, API quirks, and configuration gotchas discovered during development.

<!-- Entry format:
### Short descriptive title

**Date:** YYYY-MM-DD
**Context:** What you were doing when you hit this.
**Gotcha:** The specific pitfall and how to avoid/fix it.
-->

### Running app survives `acuity uninstall` — must quit before reinstall

**Date:** 2026-03-14
**Context:** `e2e-test.sh` ran uninstall+install in a loop. `open -a` on reinstall was a no-op because the old app was still running. New binary code never executed.
**Gotcha:** `acuity uninstall` removes the LaunchAgent plist and runs `launchctl bootout`, but the app launched via `open -a` is managed by Launch Services, not launchd. It keeps running. `UninstallCommand` now calls `pkill -f Acuity.app` first. Always verify no running instance before reinstalling.

### `ParsableCommand.main(args)` treats every element as a subcommand — drop argv[0] first

**Date:** 2026-03-14
**Context:** `main.swift` passed `CommandLine.arguments` (which includes `argv[0]` = binary path) to `ExtraDisplay.main(args)`. ArgumentParser errored: "2 unexpected arguments: '/opt/homebrew/bin/acuity', 'install'".
**Gotcha:** `ParsableCommand.main()` (no-arg form) internally drops `argv[0]`. `ParsableCommand.main(_ arguments: [String])` does NOT — it treats every element as a parse argument. Always pass `Array(CommandLine.arguments.dropFirst())` or use the no-arg form.

### Log file becomes root-owned when daemon first runs as root

**Date:** 2026-03-14
**Context:** First install used `sudo`, spawning `acuity daemon` as root. It created `/tmp/acuity.log` owned by root. User-mode writes and truncation both failed with "permission denied".
**Gotcha:** Use `~/Library/Logs/acuity.log` (always user-owned) not `/tmp/acuity.log`. If the log ends up root-owned: `sudo rm /tmp/acuity.log`. LaunchAgent plist now writes to `NSHomeDirectory()/Library/Logs/` which is always the invoking user's directory.

### E2E test requires kill + log truncate before each install iteration

**Date:** 2026-03-14
**Context:** Running `e2e-test.sh` multiple times left stale processes and log state. Assertions checked the old log (root-owned, unwritable) and found the old process still running, making "process started" checks pass for the wrong binary.
**Gotcha:** Before each install in an e2e loop: `pkill -f Acuity.app 2>/dev/null || true; sleep 1; : > ~/Library/Logs/acuity.log 2>/dev/null || true`. Without this, open-a silently no-ops (app already running) and log assertions read stale data.

### SPM cache key mismatch: `spm-` vs `v2-spm-` breaks incremental builds

**Date:** 2026-03-25
**Context:** Acuity v0.1.0 release pipeline: CI cache hit detection failed because the cache key format changed between Xcode versions. First build: cache key `spm-abc123`. Second build with updated Xcode: cache key `v2-spm-xyz789`. Rebuilt entire SPM dependency tree unnecessarily.
**Gotcha:** SPM cache keys are version-specific. Xcode upgrades change the cache format (e.g., from `spm-` to `v2-spm-`). If using caching in CI (GitHub Actions `actions/cache`), the cache key must account for Xcode version changes. Pattern: `cache-key: spm-${{ runner.os }}-${{ steps.xcode.outputs.version }}`. Without version pinning, cache misses are silent and expensive (5-10min SPM rebuilds). Always inspect the actual cache keys in CI logs after an Xcode upgrade to verify caches are being reused.
**Tags:** acuity, spm, ci, cache, xcode, incremental-build, release-pipeline

### `notarytool --wait` on GitHub Actions CI requires `timeout-minutes: 120`

**Date:** 2026-03-25
**Context:** Acuity v0.1.0 release: `notarytool submit --wait` timed out after 10 minutes even though notarization was still in progress. Apple's notarization queue was slow that day.
**Gotcha:** `notarytool submit --wait` can take 30-90 minutes when Apple's notarization service is backed up. GitHub Actions default job timeout is 6 hours per job, but the step-level timeout defaults to 360 minutes. However, if you set a lower `timeout-minutes` in the step, `--wait` will be killed mid-submission. Pattern: explicitly set `timeout-minutes: 120` (2 hours) on any step using `notarytool --wait`. Also: always run `notarytool history --latest 1` after submission to verify the job actually completed (if `--wait` times out, the submission may still be in-progress server-side). For releases, consider submitting without `--wait` and polling status in a separate step with exponential backoff.
**Tags:** acuity, notarization, notarytool, ci, github-actions, timeout, release-pipeline

### macOS 26: IOAVService.framework removed — use DisplayTransportServices.framework

**Date:** 2026-03-26
**Context:** M4 MacBook Pro (Mac16,7) running macOS 26.3.1. `dlopen("/System/Library/PrivateFrameworks/IOAVService.framework/IOAVService")` fails — not on disk, not in dyld cache. DDC brightness completely broken.
**Gotcha:** Apple removed `IOAVService.framework` in macOS 26 and moved its symbols (IOAVServiceCreateWithService, IOAVServiceReadI2C, IOAVServiceWriteI2C) to `DisplayTransportServices.framework`. The fix: try multiple candidate paths in order. See `Sources/acuity/DDC/IOAVServiceBridge.swift` `candidateLibPaths` for the full list.
**Tags:** acuity, ddc, ioavservice, macos26, dlopen, brightness

### IOAVServiceCreateFn typealias missing io_service_t — always returns nil

**Date:** 2026-03-26
**Context:** Brightness slider showed and accepted input but DDC never worked. `findService()` looped over entries but createFn always returned nil.
**Gotcha:** `IOAVServiceCreateWithService` takes TWO arguments: `(CFAllocatorRef allocator, io_service_t service)`. The typealias was declared with only one argument — on ARM64, x1 held garbage, the function always returned nil, every operation threw `serviceNotFound`. Fix: `@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?` and pass `entry` as the second argument.
**Tags:** acuity, ddc, ioavservice, swift, typealias, arm64, calling-convention

### Thunderbolt dock = 0 IOAVService IOKit entries — DDC impossible

**Date:** 2026-03-26
**Context:** Dell S2721DGF monitors through Intel JHL8440 Thunderbolt 4 dock. `IOServiceMatching("IOAVService")` returned 0 entries. DDC I2C doesn't transit Thunderbolt tunnels.
**Gotcha:** DDC/CI I2C is embedded in the display's physical connection. TB docks that convert TB→DP do NOT forward this I2C channel. `IODisplayConnect` also = 0 entries. `DisplayServicesCanChangeBrightness()` returns 0. No software path exists for DDC through a TB dock — the signal is lost at the dock hardware. Direct USB-C connection required.
**Tags:** acuity, ddc, thunderbolt, dock, ioavservice, brightness, hardware-limitation

### CGDisplayBounds returns logical POINTS, not native pixels — use native-flagged modes

**Date:** 2026-05-31
**Context:** On two Dell S2721DGF (QHD 2560x1440) panels running an active 2x HiDPI mode ("looks like 1920x1080"), `acuity list` reported native = 1920x1080. So `enable --preset all` built the 1080p ladder and never offered the gatekept QHD modes; `--preset 2x` wrote 960x540 instead of 1280x720.
**Gotcha:** `CGDisplayBounds(displayID)` returns the display rect in LOGICAL POINTS, so on a HiDPI-active display it reports the scaled "looks like" size, not the panel's physical pixels. `CGDisplayPixelsWide/High` is no better (also points on Retina). The current mode's `pixelWidth/Height` reflects whatever mode is active (here 3840x2160, a supersampled "more space" mode) and over-detects. Taking max pixels over ALL modes over-detects too (macOS offers supersampled modes above native, e.g. 5120x2880 / 4096x2304 on this panel). The correct signal: enumerate `CGDisplayCopyAllDisplayModes`, filter to modes with the IOKit native flag (`CGDisplayMode.ioFlags & 0x02000000`, kDisplayModeNativeFlag), and take the max pixel resolution among those. Empirically yields 2560x1440. Fallback when no mode is flagged: max among 1x modes (pixelWidth == width). See `DisplayEnumerator.selectNativeResolution`.
**Tags:** acuity, display, hidpi, cgdisplaybounds, native-resolution, cgdisplaymode, ioflags, retina

### "Current mode" must come from CGDisplayCopyDisplayMode, not size-matching

**Date:** 2026-05-31
**Context:** `acuity status` reported "Current mode: HiDPI active (1280x720 @2x)" when the display was actually running 1920x1080 @2x (confirmed via `system_profiler` "UI Looks like").
**Gotcha:** Don't identify the active mode by scanning `CGDisplayCopyAllDisplayModes` and matching pixel dimensions — multiple modes share the same framebuffer pixels (a 2560-pixel framebuffer is both a 1x 2560x1440 mode AND a 2x "looks like 1280x720" mode), so `.first(where:)` returns an arbitrary one. `CGDisplayCopyDisplayMode(displayID)` returns the genuinely active mode directly. A mode is HiDPI when `pixelWidth > width`; scale = `pixelWidth / width`. See `StatusCommand.describeMode`.
**Tags:** acuity, display, status, cgdisplaycopydisplaymode, hidpi, current-mode

### DDC needs a direct DisplayPort/USB-C link — HDMI on Apple Silicon also yields 0 IOAVService

**Date:** 2026-05-31
**Context:** Dell S2721DGF connected via HDMI **directly** to an M4 Pro MacBook (no dock). `ioreg -rc IOAVService | grep -c IOAVService` returned 0, and `acuity status` showed `DDC/CI: ✗ not available` — the same result as through the Thunderbolt dock.
**Gotcha:** Going "direct" is not sufficient for DDC — the *port type* is what matters. The built-in HDMI path on Apple Silicon does not expose the DDC I2C channel (IOAVService) for many displays; tested here it gives 0 IOAVService entries, identical to the TB dock (which strips the channel — see prior gotcha). DDC realistically requires a **direct DisplayPort or USB-C (DisplayPort Alt Mode)** connection. For the S2721DGF (DP + 2× HDMI, no USB-C input), the working path is a USB-C→DisplayPort cable straight from the Mac. Quick check after any change: `ioreg -rc IOAVService | grep -c IOAVService` ( >0 means a DDC transport exists). HiDPI scaling is unaffected by connection type.
**Tags:** acuity, ddc, hdmi, displayport, apple-silicon, ioavservice, connection, hardware-limitation
