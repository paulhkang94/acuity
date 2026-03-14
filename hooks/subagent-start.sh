#!/usr/bin/env bash
# SubagentStart hook: Inject session context into subagents.
# No JSONL logging — context injection only.
#
# Stdin fields: session_id, agent_id, agent_type
# Returns additionalContext with failure pattern count + verify script name.
# Requires: jq not needed (pure bash for speed)

set -euo pipefail

# Opt-out: set LOOP_SUBAGENT_CONTEXT=0 to disable context injection
[[ "${LOOP_SUBAGENT_CONTEXT:-1}" == "0" ]] && exit 0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERNS_FILE="$REPO_ROOT/.claude/memory/failure-patterns.md"

# Only inject if failure patterns file exists
[[ -f "$PATTERNS_FILE" ]] || exit 0

# Count failure patterns (lines starting with "## FP-" or "### FP-")
PATTERN_COUNT=$(grep -c '^##\? FP-\|^### FP-' "$PATTERNS_FILE" 2>/dev/null) || PATTERN_COUNT=0
[[ "$PATTERN_COUNT" -eq 0 ]] && exit 0

# Detect verify script name
if [[ -f "$REPO_ROOT/scripts/claude-verify.sh" ]]; then
  VERIFY_SCRIPT="scripts/claude-verify.sh"
elif [[ -f "$REPO_ROOT/scripts/claude-test.sh" ]]; then
  VERIFY_SCRIPT="scripts/claude-test.sh"
else
  VERIFY_SCRIPT="scripts/claude-verify.sh"
fi

echo "{\"additionalContext\":\"Context: $PATTERN_COUNT failure patterns at .claude/memory/failure-patterns.md — check before debugging. Verify: $VERIFY_SCRIPT\"}"

exit 0
