#!/usr/bin/env bash
# PreCompact hook: Log compaction event + write context checkpoint.
# Receives hook event data via stdin (JSON).
#
# Stdin fields: session_id, transcript_path, trigger (manual|auto), custom_instructions
# v3: Universal — auto-detects repo name, mkdir -p.
# Requires: jq (exits gracefully if missing)

set -euo pipefail

# Opt-out: set LOOP_METRICS=0 to disable all metrics
[[ "${LOOP_METRICS:-1}" == "0" ]] && exit 0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METRICS_FILE="$REPO_ROOT/.claude/memory/metrics.jsonl"
CHECKPOINT_FILE="$REPO_ROOT/.claude/memory/compact-checkpoint.md"
REPO_NAME="$(basename "$REPO_ROOT")"

# Graceful degradation: skip if jq isn't available
command -v jq >/dev/null 2>&1 || { exit 0; }

mkdir -p "$REPO_ROOT/.claude/memory"

INPUT=$(cat)

# Session correlation
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.claude/memory/.session_id" ]] && SESSION_ID=$(cat "$REPO_ROOT/.claude/memory/.session_id" 2>/dev/null) || true

TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null) || TRIGGER="unknown"
[[ -z "$TRIGGER" ]] && TRIGGER="unknown"

# Session-level tagging: read metadata if available (opt-in via LOOP_SESSION_TAGGING=1)
META_USER="" ; META_WT="" ; META_FID=""
META_FILE="$REPO_ROOT/.claude/memory/.session_metadata.json"
if [[ "${LOOP_SESSION_TAGGING:-0}" == "1" && -f "$META_FILE" ]]; then
  META_USER=$(jq -r '.user // ""' "$META_FILE" 2>/dev/null) || META_USER=""
  META_WT=$(jq -r '.work_type // ""' "$META_FILE" 2>/dev/null) || META_WT=""
  META_FID=$(jq -r '.feature_id // ""' "$META_FILE" 2>/dev/null) || META_FID=""
fi

# Log pre_compact event to JSONL
echo "$INPUT" | jq -c \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO_NAME" \
  --arg sid "$SESSION_ID" \
  --arg trg "$TRIGGER" \
  --arg mu "$META_USER" \
  --arg mwt "$META_WT" \
  --arg mfid "$META_FID" \
  '{
    v: 3,
    timestamp: $ts,
    repo: $repo,
    event: "pre_compact",
    trigger: (if $trg == "" then "unknown" else $trg end)
  } + (if $sid != "" then {session: $sid} else {} end)
    + (if $mu != "" then {user: $mu} else {} end)
    + (if $mwt != "" then {work_type: $mwt} else {} end)
    + (if $mfid != "" then {feature_id: $mfid} else {} end)' >> "$METRICS_FILE"

# Collect checkpoint state inline — no file-read needed after compaction
# (content goes directly into additionalContext → lands in compaction summary)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")
MODIFIED=$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null | head -20 || echo "(none)")
LAST_VERIFY=$(tail -n 50 "$METRICS_FILE" 2>/dev/null \
  | jq -r 'select(.event == "verify") | "\(.result) (\(.tier)) at \(.timestamp)"' 2>/dev/null \
  | tail -1 || echo "none")

CHECKPOINT_BODY="Branch: $BRANCH
Modified files: ${MODIFIED:-(none)}
Last verify: ${LAST_VERIFY:-none}
Checkpoint time: $TIMESTAMP"

# Also write file as fallback for cross-session recovery (source=startup)
printf '# Context Checkpoint (auto-generated %s)\n\n%s\n' \
  "$TIMESTAMP" "$CHECKPOINT_BODY" > "$CHECKPOINT_FILE"

# Return rich additionalContext — content inline so compaction summary captures it
TASKS_CHECKPOINT_FILE="$REPO_ROOT/.claude/memory/tasks-checkpoint.json"
ADDITIONAL_CTX="=== COMPACTION CONTEXT CHECKPOINT ===
$CHECKPOINT_BODY

CRITICAL — BEFORE THIS COMPACTION COMPLETES:
1. Call the TaskList tool RIGHT NOW to get all current tasks.
2. Write the result as JSON to $TASKS_CHECKPOINT_FILE in this exact format:
   [{\"id\":\"1\",\"subject\":\"...\",\"status\":\"pending\",\"blockedBy\":[]}, ...]
   Include ALL tasks with status pending or in_progress. Skip completed tasks older than 24h.
3. Use the Write tool to create the file — write valid JSON only, no prose.
4. Only after writing that file should compaction proceed.
==================================="

printf '%s' "$ADDITIONAL_CTX" | jq -Rs '{ additionalContext: . }'

exit 0
