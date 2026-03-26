#!/usr/bin/env bash
# test-ddc-brightness.sh — automated DDC brightness validation
# Tests the full pipeline: list → read logs → brightness sweep → log analysis
# All PHK debug output is captured and analysed.
set -euo pipefail

BINARY="$(cd "$(dirname "$0")/.." && pwd)/.build/release/acuity"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/ddc-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/test.log"
PASS=0
FAIL=0

info()  { echo "  [INFO]  $*" | tee -a "$LOG"; }
ok()    { echo "  [PASS]  $*" | tee -a "$LOG"; PASS=$((PASS+1)); }
fail()  { echo "  [FAIL]  $*" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
warn()  { echo "  [WARN]  $*" | tee -a "$LOG"; }
sep()   { echo "─────────────────────────────────────────" | tee -a "$LOG"; }

echo "" | tee -a "$LOG"
echo "PHK DDC Brightness Test — $(date)" | tee -a "$LOG"
sep

# ── 1. Binary exists ─────────────────────────────────────────────────────────
sep; info "1. Binary check"
if [[ -x "$BINARY" ]]; then
    ok "Binary found: $BINARY"
else
    fail "Binary not found — run: cd acuity && swift build -c release"
    exit 1
fi

# ── 2. Display list ───────────────────────────────────────────────────────────
sep; info "2. Display enumeration"
LIST_OUT="$OUT_DIR/list.txt"
"$BINARY" list 2>&1 | tee "$LIST_OUT" | tee -a "$LOG"

DISPLAY_COUNT=$(grep -c "^\s*[0-9]\+\." "$LIST_OUT" 2>/dev/null || echo "0")
if [[ "$DISPLAY_COUNT" -gt 0 ]]; then
    ok "Found $DISPLAY_COUNT external display(s)"
else
    fail "No external displays found — plug in a monitor"
    exit 1
fi

# Extract vendor:product from first display for targeted commands
FIRST_DISPLAY=$(grep "ID\s*:" "$LIST_OUT" | head -1 | grep -oE '0x[0-9A-Fa-f]+:0x[0-9A-Fa-f]+' || echo "")
info "First display ID: ${FIRST_DISPLAY:-<auto>}"

# ── 3. Screenshot: baseline ───────────────────────────────────────────────────
sep; info "3. Baseline screenshot"
screencapture -x "$OUT_DIR/screen-baseline.png" 2>/dev/null && \
    ok "Baseline screenshot: $OUT_DIR/screen-baseline.png" || \
    info "screencapture not available (headless?)"

# ── 4. DDC pipeline trace: IOAVService discovery ─────────────────────────────
sep; info "4. IOAVService discovery (PHK log trace)"
TRACE_OUT="$OUT_DIR/trace-brightness-50.txt"

# Run brightness set and capture ALL output (stdout = PHK prints + result)
set +e
"$BINARY" brightness 50 >"$TRACE_OUT" 2>&1
EXIT_CODE=$?
set -e
cat "$TRACE_OUT" | tee -a "$LOG"

info "Exit code: $EXIT_CODE"

# Analyse PHK trace.
# grep -c exits 1 on zero matches; capture stdout directly via $() — do NOT
# use "|| echo 0" because that adds a second line and breaks arithmetic.
# grep -c exits 1 on zero matches; with set -e, $() propagates that exit code.
# Use "|| n=0" to absorb the failure without a second echo.
phk_cnt() { local n; n=$(grep -c "$1" "$TRACE_OUT" 2>/dev/null) || n=0; printf '%d' "$n"; }
DLOPEN_OK=$(phk_cnt "IOAVServiceBridge.init: dlopen OK")
SYMBOLS_OK=$(phk_cnt "symbols resolved OK")
ENTRIES=$(phk_cnt "findService: entry\[")
SERVICE_FOUND=$(phk_cnt "service found")
WRITE_OK=$(phk_cnt "writeI2C status=0")
WRITE_FAIL=$(phk_cnt "FAILED")
CREATE_NIL=$(phk_cnt "createFn returned nil")

sep; info "PHK trace analysis:"
info "  dlopen OK:              $DLOPEN_OK"
info "  symbols OK:             $SYMBOLS_OK"
info "  IOAVService IOKit entries: $ENTRIES"
info "  service handle acquired:  $SERVICE_FOUND"
info "  createFn returned nil:   $CREATE_NIL"
info "  writeI2C OK:             $WRITE_OK"
info "  writeI2C FAILED:         $WRITE_FAIL"

# Software correctness checks (FAIL = bug in Acuity code)
if [[ $DLOPEN_OK -gt 0 ]]; then
    ok "IOAVService symbols loaded from system framework"
else
    fail "IOAVService.framework failed to load — check Apple Silicon + framework path"
fi

if [[ $SYMBOLS_OK -gt 0 ]]; then
    ok "IOAVServiceCreateWithService / ReadI2C / WriteI2C symbols resolved"
else
    fail "Required IOAVService symbols missing — SPI may have changed"
fi

# Hardware/connection checks (WARN = hardware limitation, not a code bug)
if [[ $ENTRIES -gt 0 ]]; then
    ok "$ENTRIES IOAVService IOKit entr(y/ies) found"
else
    warn "0 IOAVService IOKit entries — monitors likely connected via Thunderbolt dock"
    warn "DDC/CI I2C does not transit TB docks; direct USB-C connection needed"
fi

if [[ $SERVICE_FOUND -gt 0 ]]; then
    ok "IOAVService handle acquired for display"
elif [[ $ENTRIES -gt 0 && $CREATE_NIL -gt 0 ]]; then
    fail "IOAVService entries found but createFn returned nil (unexpected — file a bug)"
else
    warn "No IOAVService handle — expected when no IOKit DDC entries present"
fi

if [[ $WRITE_OK -gt 0 ]]; then
    ok "writeI2C succeeded — DDC reached the monitor ✓"
elif [[ $WRITE_FAIL -gt 0 ]]; then
    fail "writeI2C returned non-zero — monitor rejected DDC command"
elif [[ $SERVICE_FOUND -gt 0 ]]; then
    fail "Service acquired but no writeI2C attempt — unexpected code path"
else
    warn "No DDC write attempted — no service handle (hardware limited)"
fi

# ── 5. Brightness sweep: 10 → 75 → 50 ────────────────────────────────────────
sep; info "5. Brightness sweep (10 → 75 → 50) — watch your display"

if [[ $SERVICE_FOUND -gt 0 ]]; then
    for LEVEL in 10 75 50; do
        info "  Setting brightness → $LEVEL"
        SWEEP_OUT="$OUT_DIR/trace-brightness-${LEVEL}.txt"
        set +e
        "$BINARY" brightness "$LEVEL" >"$SWEEP_OUT" 2>&1
        SWEEP_EXIT=$?
        set -e
        cat "$SWEEP_OUT" >> "$LOG"

        SWEEP_OK=$(grep -c "writeI2C status=0" "$SWEEP_OUT" 2>/dev/null) || SWEEP_OK=0
        if [[ $SWEEP_EXIT -eq 0 && $SWEEP_OK -gt 0 ]]; then
            ok "brightness $LEVEL: writeI2C OK ✓"
        else
            fail "brightness $LEVEL: exit=$SWEEP_EXIT writeOK=$SWEEP_OK"
        fi
        screencapture -x "$OUT_DIR/screen-brightness-${LEVEL}.png" 2>/dev/null || true
        sleep 1
    done
else
    warn "Skipping sweep — DDC hardware not accessible (Thunderbolt dock)"
fi

# ── 6. Screencap: menubar open ────────────────────────────────────────────────
sep; info "6. Capturing current menu state via screencapture"
screencapture -x "$OUT_DIR/screen-final.png" 2>/dev/null && \
    ok "Final screenshot: $OUT_DIR/screen-final.png" || true

# ── 7. system_profiler display connection type ───────────────────────────────
sep; info "7. Display connection info (system_profiler)"
system_profiler SPDisplaysDataType 2>/dev/null | grep -A 5 "Display Type\|Connection Type\|Vendor ID\|Product ID\|DDC" | tee -a "$LOG" | head -40 || true

# ── 8. IOKit: IOAVService registry dump ──────────────────────────────────────
sep; info "8. IOKit IOAVService registry entries"
IOAV_OUT="$OUT_DIR/ioreg-ioavservice.txt"
ioreg -r -n IOAVService -l 2>/dev/null | head -80 | tee "$IOAV_OUT" | tee -a "$LOG" || info "(ioreg -n IOAVService returned nothing — no DDC bridge visible)"

IOAV_ENTRIES=$(grep -c "IOAVService" "$IOAV_OUT" 2>/dev/null) || IOAV_ENTRIES=0
if [[ $IOAV_ENTRIES -gt 0 ]]; then
    ok "IOKit shows $IOAV_ENTRIES IOAVService line(s)"
else
    warn "No IOAVService entries in IOKit — DDC via TB dock is hardware-limited"
fi

# ── 9. Summary ────────────────────────────────────────────────────────────────
sep
echo "" | tee -a "$LOG"
echo "══════════════════════════════════════" | tee -a "$LOG"
echo "  Results: $PASS passed, $FAIL failed" | tee -a "$LOG"
echo "  Artifacts: $OUT_DIR/" | tee -a "$LOG"
echo "══════════════════════════════════════" | tee -a "$LOG"

ls -la "$OUT_DIR/" | tee -a "$LOG"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
