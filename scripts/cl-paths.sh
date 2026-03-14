#!/usr/bin/env bash
# cl-paths.sh — Single source of truth for all shared LOOP file paths. # path-safety: no-euo — sourceable library; sourcing script provides error handling
#
# USAGE: source this file in any script that reads or writes a shared LOOP path.
#   source "$(dirname "$0")/cl-paths.sh"   # from scripts/
#   source "$REPO_ROOT/scripts/cl-paths.sh"  # from hooks/
#
# WHY: Implicit string coupling between producer and consumer scripts is the
# primary cause of broken feedback loops (Type B gap). Both sides must reference
# the same variable, not independently hardcode the same path string.
#
# CONTRACT: When adding a new shared path, add it here AND in cl-io-contracts.txt.
# When a producer writes to a path, grep cl-io-contracts.txt to confirm a consumer exists.

# Require REPO_ROOT to be set before sourcing. Callers must set it.
# Example: REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
  echo "[cl-paths] ERROR: REPO_ROOT must be set before sourcing cl-paths.sh" >&2
  exit 1
fi

# ── Schema Validation Helpers ────────────────────────────────────────────────
# Validate a JSONL file has required fields in its most recent entry.
# Usage: cl_paths_validate_schema PATH REQUIRED_FIELDS
# Returns: 0 if valid, 1 if invalid (prints error)
cl_paths_validate_schema() {
  local path="$1"
  local required="$2"  # comma-separated field names
  [[ ! -f "$path" ]] && return 0  # missing file = not a schema error
  local last_line
  last_line=$(tail -1 "$path" 2>/dev/null) || return 0
  [[ -z "$last_line" ]] && return 0
  command -v jq &>/dev/null || return 0
  for field in ${required//,/ }; do
    if ! echo "$last_line" | jq -e "has(\"$field\")" &>/dev/null; then
      echo "[cl-paths] Schema warning: $path missing field '$field' in last entry" >&2
      return 1
    fi
  done
  return 0
}

# ── Memory directory ────────────────────────────────────────────────────────
CL_MEMORY_DIR="${REPO_ROOT}/.claude/memory"

# ── Core database ──────────────────────────────────────────────────────────
CL_LEARNINGS_DB="${CL_DB_PATH:-${CL_MEMORY_DIR}/learnings.db}"

# ── Metrics pipeline ────────────────────────────────────────────────────────
# Producer: session-start.sh, session-end.sh, claude-log-failure.sh, claude-log-subagent.sh
# Consumer: analyze-metrics skill, cl-analytics.sh, cl-metrics-extended.sh, cl-session-summary.sh
CL_METRICS="${CL_MEMORY_DIR}/metrics.jsonl"
# Schema: {"v":"number","timestamp":"ISO8601","repo":"string?","event":"string","session":"string?","...":"varies"}
CL_METRICS_SCHEMA='v,timestamp,event'  # required fields
CL_METRICS_ARCHIVE_DIR="${CL_MEMORY_DIR}/metrics-archive"

# ── Acceptance signal pipeline ───────────────────────────────────────────────
# Producer: hooks/outcome-verify.sh (PostToolUse — did Claude act on the CL warning?)
# Consumer: scripts/cl-quality-audit.sh (reads signals → updates DB acceptance counts)
CL_ACCEPTANCE_SIGNALS="${ACCEPTANCE_SIGNALS_FILE:-${CL_MEMORY_DIR}/acceptance-signals.jsonl}"
# Schema: {"ts":"ISO8601","tool":"string","warning_type":"string","acted_on":"boolean","session":"string?","hook":"string"}
CL_ACCEPTANCE_SIGNALS_SCHEMA='ts,tool,warning_type,acted_on'  # required fields
CL_ACCEPTANCE_SIGNALS_PROCESSED="${CL_MEMORY_DIR}/acceptance-signals-processed.jsonl"

# ── Rule coverage pipeline ──────────────────────────────────────────────────
# Producer: scripts/cl-check.sh (PreToolUse — logs which rules fired)
# Consumer: scripts/cl-quality-audit.sh (dead rule detection, 30-day coverage)
CL_RULE_COVERAGE="${RULE_COVERAGE_LOG:-${CL_MEMORY_DIR}/rule-coverage.jsonl}"
# Schema: {"ts":"ISO8601","rule_id":"string","applicable":"boolean","context":"string?"}
CL_RULE_COVERAGE_SCHEMA='ts,rule_id,applicable'  # required fields

# ── Session tracking (ephemeral, cleared on session start) ──────────────────
# Producer: hooks/session-start.sh
# Consumer: hooks/session-end.sh, scripts/cl-session-summary.sh
CL_SESSION_ID_FILE="${CL_MEMORY_DIR}/.session_id"
CL_SESSION_START_EPOCH="${CL_MEMORY_DIR}/.session_start_epoch"
CL_SESSION_METADATA="${CL_MEMORY_DIR}/.session_metadata.json"

# ── CL warning count (ephemeral, cleared after outcome-verify.sh reads it) ──
# Producer: scripts/cl-check.sh (writes "count:type" after warning)
# Consumer: hooks/outcome-verify.sh (reads to detect pending warning)
CL_WARNING_COUNT_FILE="${CL_MEMORY_DIR}/.cl_warning_count"

# ── Model routing pipeline ──────────────────────────────────────────────────
# Producer: scripts/cl-model-router.sh (routing decisions log)
# Consumer: scripts/cl-routing-metrics.sh (analysis of routing effectiveness)
CL_ROUTER_CONFIG_DIR="${CL_ROUTER_CONFIG_DIR:-$HOME/.config/loop}"
CL_ROUTING_DECISIONS="${CL_ROUTER_CONFIG_DIR}/routing_decisions.jsonl"
# Schema: {"event":"string","task_id":"string","model":"string","complexity":"string","timestamp":"ISO8601","rationale":"string?"}
CL_ROUTING_DECISIONS_SCHEMA='event,task_id,model,timestamp'  # required fields (event=routing_decision or routing_feedback)
CL_COST_RATES="${CL_ROUTER_CONFIG_DIR}/cost_rates.json"

# ── Real cost tracking (ccusage) ─────────────────────────────────────────────
# Producer: hooks/session-end-cost.sh (Stop hook — writes real ccusage data at session end)
# Consumer: scripts/cl-session-summary.sh (reads to use real cost vs tool-failure estimate)
# NOTE: This is a GLOBAL file (HOME-based, not REPO_ROOT-based). All repos share it.
CL_SESSION_COSTS="${HOME}/.claude/memory/session-costs.jsonl"
# Schema: {"ts":"ISO8601","session_id":"string","ccusage":{"totals":{"totalCost":"number","totalTokens":"number",...}}}
CL_SESSION_COSTS_SCHEMA='ts,session_id'  # ccusage may be null if unavailable; when present: ccusage.totalCost (session) or ccusage.totals.totalCost (fallback)

# ── Context recovery ─────────────────────────────────────────────────────────
# Producer: hooks/pre-compact.sh
# Consumer: hooks/session-start.sh (source=compact → inject into additionalContext)
CL_COMPACT_CHECKPOINT="${CL_MEMORY_DIR}/compact-checkpoint.md"

# ── Agent results cache ──────────────────────────────────────────────────────
# Producer: scripts/claude-log-subagent.sh (SubagentStop)
# Consumer: manual inspection / analyze-metrics skill
CL_AGENT_RESULTS="${CL_MEMORY_DIR}/agent-results.jsonl"

# ── Failure patterns ─────────────────────────────────────────────────────────
# Producer: scripts/claude-log-failure.sh, scripts/claude-post-session-analysis.sh
# Consumer: scripts/cl-check.sh, hooks/subagent-start.sh (context injection)
CL_FAILURE_PATTERNS="${CL_MEMORY_DIR}/failure-patterns.md"
