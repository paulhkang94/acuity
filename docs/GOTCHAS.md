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
