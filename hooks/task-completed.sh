#!/usr/bin/env bash
# TaskCompleted hook: Quality gate — require recent verify pass before completing tasks.
# Default OFF (opt-in via LOOP_TASK_GATE=1) since this can be disruptive.
#
# Stdin fields: session_id, task_id, task_subject, task_description (optional)
# Exit 0 = allow completion, Exit 2 = block with error message.
# Requires: jq (exits gracefully if missing — allows completion)

set -euo pipefail

# Default OFF — must opt in with LOOP_TASK_GATE=1
[[ "${LOOP_TASK_GATE:-0}" == "1" ]] || exit 0

# Kill switch
[[ "${LOOP_METRICS:-1}" == "0" ]] && exit 0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METRICS_FILE="$REPO_ROOT/.claude/memory/metrics.jsonl"

# If no metrics file, allow completion (no data to gate on)
[[ -f "$METRICS_FILE" ]] || exit 0

# Graceful degradation: allow completion if jq missing
command -v jq >/dev/null 2>&1 || exit 0

# Check for a verify pass within the last 10 minutes
if date -v -1d +%s &>/dev/null 2>&1; then
  # macOS date
  CUTOFF=$(date -u -v -10M +"%Y-%m-%dT%H:%M:%SZ")
else
  # GNU date
  CUTOFF=$(date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")
fi

RECENT_PASS=$(tail -n 100 "$METRICS_FILE" | jq -r --arg cutoff "$CUTOFF" \
  'select(.event == "verify" and .result == "pass" and .timestamp >= $cutoff) | .timestamp' 2>/dev/null | tail -1)

if [[ -z "$RECENT_PASS" ]]; then
  echo "No recent verify pass. Run scripts/claude-verify.sh before completing tasks." >&2
  exit 2
fi

exit 0
