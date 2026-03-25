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
