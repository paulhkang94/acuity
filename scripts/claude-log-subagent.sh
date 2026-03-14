#!/usr/bin/env bash
# SubagentStop hook: Log subagent completions to metrics JSONL.
# Receives hook event data via stdin (JSON).
# Appends a single JSONL line to .claude/memory/metrics.jsonl
#
# v4: Universal — auto-detects repo name, mkdir -p, is_interrupt field, duration_ms, exit_code.
# Requires: jq (exits gracefully if missing)

set -euo pipefail

# Source version constants
source "$(dirname "$0")/cl-version.sh" 2>/dev/null || { CL_JSONL_VERSION=3; CL_SUBAGENT_JSONL_VERSION=4; CL_DB_SCHEMA_VERSION=3; }

# Opt-out: set LOOP_METRICS=0 or LOOP_METRICS_SUBAGENTS=0 to disable
[[ "${LOOP_METRICS:-1}" == "0" || "${LOOP_METRICS_SUBAGENTS:-1}" == "0" ]] && exit 0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METRICS_FILE="$REPO_ROOT/.claude/memory/metrics.jsonl"
REPO_NAME="$(basename "$REPO_ROOT")"

# Graceful degradation: skip logging if jq isn't available
command -v jq >/dev/null 2>&1 || { exit 0; }

mkdir -p "$(dirname "$METRICS_FILE")"

INPUT=$(cat)

# Session correlation: extract native session_id from hook stdin JSON (first-party)
# Falls back to .session_id file for backwards compatibility
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.claude/memory/.session_id" ]] && SESSION_ID=$(cat "$REPO_ROOT/.claude/memory/.session_id" 2>/dev/null) || true

# Session-level tagging: read metadata if available (opt-in via LOOP_SESSION_TAGGING=1)
META_USER="" ; META_WT="" ; META_FID=""
META_FILE="$REPO_ROOT/.claude/memory/.session_metadata.json"
if [[ "${LOOP_SESSION_TAGGING:-0}" == "1" && -f "$META_FILE" ]]; then
  META_USER=$(jq -r '.user // ""' "$META_FILE" 2>/dev/null) || META_USER=""
  META_WT=$(jq -r '.work_type // ""' "$META_FILE" 2>/dev/null) || META_WT=""
  META_FID=$(jq -r '.feature_id // ""' "$META_FILE" 2>/dev/null) || META_FID=""
fi

# Note: jq's `// "unknown"` does NOT catch empty strings "".
# Always add the `if . == ""` check for fields that may be empty.
echo "$INPUT" | jq -c \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO_NAME" \
  --arg sid "$SESSION_ID" \
  --arg mu "$META_USER" \
  --arg mwt "$META_WT" \
  --arg mfid "$META_FID" \
  --argjson v "$CL_SUBAGENT_JSONL_VERSION" \
  '{
    v: $v,
    timestamp: $ts,
    repo: $repo,
    event: "subagent_stop",
    agent_type: ((.agent_type // "unknown") | if . == "" then "unknown" else . end),
    agent_id: ((.agent_id // "unknown") | if . == "" then "unknown" else . end),
    is_interrupt: (.is_interrupt // false),
    duration_ms: (.duration_ms // 0),
    exit_code: (.exit_code // 0)
  } + (if $sid != "" then {session: $sid} else {} end)
    + (if $mu != "" then {user: $mu} else {} end)
    + (if $mwt != "" then {work_type: $mwt} else {} end)
    + (if $mfid != "" then {feature_id: $mfid} else {} end)' >> "$METRICS_FILE"

exit 0
