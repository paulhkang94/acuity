#!/usr/bin/env bash
# End-to-end verification for extradisplay install + menubar.
# Runs install, waits for LaunchAgent to start, checks logs + screenshots.
# Usage: bash scripts/e2e-test.sh [--no-install]  (--no-install skips rebuild)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_INSTALL="${1:-}"
PASS=0; FAIL=0
LOG="/tmp/extradisplay-e2e-$(date +%Y%m%d-%H%M%S).log"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1" >&2; FAIL=$((FAIL+1)); }
info() { echo "  ℹ $1"; }

echo "=== extradisplay e2e test — $(date) ===" | tee "$LOG"
echo ""

# ── 0. Pre-flight ────────────────────────────────────────────────────────────

echo "▶ Pre-flight checks"
[[ "$(id -u)" != "0" ]] && ok "Not running as root" || fail "Must not run as root"
[[ -f Resources/Info.plist ]] && ok "Resources/Info.plist exists" || fail "Resources/Info.plist missing"
[[ -f scripts/build-app.sh ]] && ok "scripts/build-app.sh exists" || fail "scripts/build-app.sh missing"

# ── 1. Install ───────────────────────────────────────────────────────────────

if [[ "$SKIP_INSTALL" != "--no-install" ]]; then
    echo ""
    echo "▶ Running install (this takes ~10s for build)"
    # Kill any running app instance first — open -a won't launch a second instance
    pkill -f "ExtradisplayApp.app" 2>/dev/null || true
    sleep 1
    extradisplay uninstall 2>/dev/null || true
    # Truncate stale log so log checks only see fresh output
    : > $HOME/Library/Logs/extradisplay.log 2>/dev/null || true
    if bash scripts/install.sh 2>&1 | tee -a "$LOG"; then
        ok "install.sh completed"
    else
        fail "install.sh failed"
        echo "FATAL: install failed. Check $LOG"; exit 1
    fi
fi

# ── 2. Binary checks ─────────────────────────────────────────────────────────

echo ""
echo "▶ Binary checks"

BINARY="/opt/homebrew/bin/extradisplay"
APP="$HOME/Applications/ExtradisplayApp.app"

[[ -f "$BINARY" ]] && ok "CLI binary exists: $BINARY" || fail "CLI binary missing"
OWNER=$(stat -f "%Su" "$BINARY" 2>/dev/null)
[[ "$OWNER" != "root" ]] && ok "Binary owned by user ($OWNER)" || fail "Binary is root-owned — will be SIGKILL'd"

[[ -d "$APP" ]] && ok "App bundle exists: $APP" || fail "App bundle missing"
[[ -f "$APP/Contents/Info.plist" ]] && ok "Info.plist in bundle" || fail "Info.plist missing from bundle"
[[ -f "$APP/Contents/MacOS/extradisplay" ]] && ok "Binary inside bundle" || fail "Binary missing from bundle"

# Verify Info.plist has required keys
LS_UI=$(plutil -extract LSUIElement raw "$APP/Contents/Info.plist" 2>/dev/null)
[[ "$LS_UI" == "true" ]] && ok "LSUIElement = YES" || fail "LSUIElement not YES (app will show in Dock)"

NS_PC=$(plutil -extract NSPrincipalClass raw "$APP/Contents/Info.plist" 2>/dev/null)
[[ "$NS_PC" == "NSApplication" ]] && ok "NSPrincipalClass = NSApplication" || fail "NSPrincipalClass wrong: $NS_PC"

# Verify MD5 of bundle binary matches CLI binary
MD5_CLI=$(md5 -q "$BINARY")
MD5_APP=$(md5 -q "$APP/Contents/MacOS/extradisplay")
[[ "$MD5_CLI" == "$MD5_APP" ]] && ok "Bundle binary matches CLI binary (same build)" || fail "Bundle binary differs from CLI binary"

# ── 3. LaunchAgent checks ────────────────────────────────────────────────────

echo ""
echo "▶ LaunchAgent checks"

PLIST="$HOME/Library/LaunchAgents/com.extradisplay.agent.plist"
[[ -f "$PLIST" ]] && ok "LaunchAgent plist installed" || fail "LaunchAgent plist missing"

if [[ -f "$PLIST" ]]; then
    CMD=$(plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null)
    # Menubar mode uses `open -a App.app`; daemon mode uses the binary directly
    if [[ "$CMD" == "/usr/bin/open" ]]; then
        APP_ARG=$(plutil -extract ProgramArguments.2 raw "$PLIST" 2>/dev/null)
        [[ "$APP_ARG" == *"ExtradisplayApp.app" ]] && \
            ok "LaunchAgent uses open -a ExtradisplayApp.app (menubar mode)" || \
            fail "LaunchAgent open -a target wrong: $APP_ARG"
        KEEPALIVE=$(plutil -extract KeepAlive raw "$PLIST" 2>/dev/null)
        [[ "$KEEPALIVE" == "false" ]] && ok "KeepAlive=false (open exits immediately)" || fail "KeepAlive should be false for open -a mode"
    else
        [[ "$CMD" == *"extradisplay" ]] && ok "LaunchAgent daemon mode: $CMD" || fail "LaunchAgent wrong cmd: $CMD"
    fi
fi

AGENT_LOADED=$(launchctl list com.extradisplay.agent 2>/dev/null | grep -c "Label" || echo 0)
[[ "$AGENT_LOADED" -gt 0 ]] && ok "LaunchAgent loaded in launchd" || fail "LaunchAgent not loaded"

# ── 4. Process checks ────────────────────────────────────────────────────────

echo ""
echo "▶ Process checks (waiting up to 8s for startup)"

for i in $(seq 1 10); do
    if pgrep -f "ExtradisplayApp.app" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

PID=$(pgrep -f "ExtradisplayApp.app" 2>/dev/null | head -1 || echo "")
if [[ -n "$PID" ]]; then
    ok "ExtradisplayApp running (PID $PID)"
    PROC_USER=$(ps -o user= -p "$PID" 2>/dev/null | tr -d ' ')
    [[ "$PROC_USER" != "root" ]] && ok "Process running as user ($PROC_USER)" || fail "Process running as root — will have issues"
else
    fail "ExtradisplayApp not running after 10s"
    info "Agent status: $(launchctl list com.extradisplay.agent 2>/dev/null | grep LastExitStatus || echo unknown)"
fi

# No root daemon
ROOT_DAEMON=$(pgrep -f "extradisplay daemon" 2>/dev/null || echo "")
[[ -z "$ROOT_DAEMON" ]] && ok "No root daemon running" || fail "Root daemon still running (PID $ROOT_DAEMON) — cleanup needed"

# ── 5. Log checks ────────────────────────────────────────────────────────────

echo ""
echo "▶ Log checks ($HOME/Library/Logs/extradisplay.log)"

sleep 3  # give the open-a launched app time to write its startup log
if [[ -f $HOME/Library/Logs/extradisplay.log ]]; then
    ALL_LOG=$(cat $HOME/Library/Logs/extradisplay.log)
    # These come from the menubar app (StartCommand) writing explicitly to the log
    echo "$ALL_LOG" | grep -q "menubar started" && \
        ok "Menubar started message in log" || fail "Menubar started message not in log"
    echo "$ALL_LOG" | grep -q "BrightnessKeyInterceptor" && \
        ok "BrightnessKeyInterceptor message in log" || fail "BrightnessKeyInterceptor message not in log"
    # Stale root daemon check: daemon starting should NOT appear AFTER the menubar started line
    AFTER_START=$(echo "$ALL_LOG" | awk '/menubar started/{found=1} found{print}')
    echo "$AFTER_START" | grep -q "daemon starting" && \
        fail "OLD root daemon still logging AFTER menubar start (orphan daemon)" || \
        ok "No stale daemon messages after menubar start"
    info "Last 5 log lines:"
    tail -5 $HOME/Library/Logs/extradisplay.log | sed 's/^/    /'
else
    fail "$HOME/Library/Logs/extradisplay.log not found"
fi

# ── 6. Screenshot verification ───────────────────────────────────────────────

echo ""
echo "▶ Screenshot verification"

SHOT="/tmp/extradisplay-e2e-menubar.png"
screencapture -R "960,0,960,28" -x "$SHOT"

# Pixel-level check: compare screenshot with/without icon using ImageMagick
# if available; otherwise just save and report path
if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    TOOL=$(command -v magick || command -v convert)
    # Get mean brightness of left portion (where icon would be)
    MEAN=$("$TOOL" "$SHOT" -crop "80x28+0+0" +repage -format "%[fx:mean]" info: 2>/dev/null || echo "0")
    info "Icon region brightness: $MEAN (>0.01 = non-empty)"
    [[ $(echo "$MEAN > 0.01" | bc -l 2>/dev/null || echo 0) -eq 1 ]] && \
        ok "Menubar region appears non-empty (icon likely visible)" || \
        fail "Menubar region appears empty"
else
    info "ImageMagick not available — pixel check skipped"
fi

ok "Screenshot saved: $SHOT"
info "Open with: open $SHOT"

# ── 7. Functional checks ─────────────────────────────────────────────────────

echo ""
echo "▶ Functional checks"

extradisplay list 2>&1 | grep -q "HiDPI ✓" && ok "extradisplay list shows HiDPI ✓" || fail "extradisplay list failed or HiDPI not shown"

# ── 8. Summary ───────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "  Log: $LOG"
echo "  Screenshot: $SHOT"
echo "══════════════════════════════════════"

[[ $FAIL -eq 0 ]] && echo "✅ All checks passed" || echo "❌ $FAIL check(s) failed"
exit $FAIL
