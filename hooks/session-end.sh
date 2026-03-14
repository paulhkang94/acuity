#!/usr/bin/env bash
# SessionEnd hook: Log session end event.
# Receives hook event data via stdin (JSON).
#
# Stdin fields: session_id, transcript_path, reason (clear|logout|prompt_input_exit|other)
# v3: Universal — auto-detects repo name, mkdir -p.
# Requires: jq (exits gracefully if missing)

set -euo pipefail

# Opt-out: set LOOP_METRICS=0 to disable all metrics
[[ "${LOOP_METRICS:-1}" == "0" ]] && exit 0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METRICS_FILE="$REPO_ROOT/.claude/memory/metrics.jsonl"
REPO_NAME="$(basename "$REPO_ROOT")"

# Graceful degradation: skip if jq isn't available
command -v jq >/dev/null 2>&1 || { exit 0; }

mkdir -p "$(dirname "$METRICS_FILE")"

INPUT=$(cat)

# Session correlation
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.claude/memory/.session_id" ]] && SESSION_ID=$(cat "$REPO_ROOT/.claude/memory/.session_id" 2>/dev/null) || true

REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null) || REASON="unknown"
[[ -z "$REASON" ]] && REASON="unknown"

# Session-level tagging: read metadata if available (opt-in via LOOP_SESSION_TAGGING=1)
META_USER="" ; META_WT="" ; META_FID=""
META_FILE="$REPO_ROOT/.claude/memory/.session_metadata.json"
if [[ "${LOOP_SESSION_TAGGING:-0}" == "1" && -f "$META_FILE" ]]; then
  META_USER=$(jq -r '.user // ""' "$META_FILE" 2>/dev/null) || META_USER=""
  META_WT=$(jq -r '.work_type // ""' "$META_FILE" 2>/dev/null) || META_WT=""
  META_FID=$(jq -r '.feature_id // ""' "$META_FILE" 2>/dev/null) || META_FID=""
fi

# Calculate session duration (item #8)
SESSION_DURATION=""
START_EPOCH_FILE="$REPO_ROOT/.claude/memory/.session_start_epoch"
if [[ -f "$START_EPOCH_FILE" ]]; then
  START_EPOCH=$(cat "$START_EPOCH_FILE" 2>/dev/null) || START_EPOCH=""
  if [[ -n "$START_EPOCH" ]]; then
    END_EPOCH=$(date +%s)
    SESSION_DURATION=$((END_EPOCH - START_EPOCH))
  fi
  # Always clean up here; export the value so cl-session-summary.sh can use it
  # without re-reading the file (avoids a race condition on slow systems).
  rm -f "$START_EPOCH_FILE" 2>/dev/null || true
  export CL_SESSION_DURATION_SECONDS="${SESSION_DURATION:-0}"
fi

# Post-session reflection (before logging)
REFLECT_SCRIPT="$REPO_ROOT/scripts/cl-reflect.sh"
if [[ -x "$REFLECT_SCRIPT" && "${LOOP_REFLECTION:-1}" != "0" ]]; then
  bash "$REFLECT_SCRIPT" "$REPO_ROOT" 2>/dev/null || true
fi

# Log session_end event to JSONL
echo "$INPUT" | jq -c \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO_NAME" \
  --arg sid "$SESSION_ID" \
  --arg rsn "$REASON" \
  --arg dur "$SESSION_DURATION" \
  --arg mu "$META_USER" \
  --arg mwt "$META_WT" \
  --arg mfid "$META_FID" \
  '{
    v: 3,
    timestamp: $ts,
    repo: $repo,
    event: "session_end",
    reason: (if $rsn == "" then "unknown" else $rsn end)
  } + (if $sid != "" then {session: $sid} else {} end)
    + (if $dur != "" then {session_duration_seconds: ($dur | tonumber)} else {} end)
    + (if $mu != "" then {user: $mu} else {} end)
    + (if $mwt != "" then {work_type: $mwt} else {} end)
    + (if $mfid != "" then {feature_id: $mfid} else {} end)' >> "$METRICS_FILE"

# Session summary: emit session_cost, fingerprint health, and low-quality warnings
timeout 15 bash "$REPO_ROOT/scripts/cl-session-summary.sh" 2>/dev/null || true

# Hub sync: push high-quality fingerprints to central hub (opt-in via CL_HUB_REPO)
if [[ -n "${CL_HUB_REPO:-}" && -x "$REPO_ROOT/scripts/cl-hub-sync.sh" ]]; then
  timeout 15 bash "$REPO_ROOT/scripts/cl-hub-sync.sh" --push 2>/dev/null || true
fi

exit 0
