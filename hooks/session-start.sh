#!/usr/bin/env bash
# SessionStart hook: Log session start + bridge session_id + optional OTEL setup.
# Receives hook event data via stdin (JSON).
# Fires on: startup, resume, clear, compact
#
# Stdin fields: session_id, transcript_path, cwd, source, model
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

mkdir -p "$REPO_ROOT/.claude/memory"

INPUT=$(cat)

# Bridge session_id to file — earliest possible, before auto-activate
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
if [[ -n "$SESSION_ID" ]]; then
  echo "$SESSION_ID" > "$REPO_ROOT/.claude/memory/.session_id" 2>/dev/null || true
fi

# Extract source and model
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null) || SOURCE="unknown"
[[ -z "$SOURCE" ]] && SOURCE="unknown"
MODEL=$(echo "$INPUT" | jq -r '.model // ""' 2>/dev/null) || MODEL=""

# Session-level tagging: write metadata file if opted in (BEFORE logging so session_start includes it)
# Opt-in: set LOOP_SESSION_TAGGING=1 to enable
META_USER="" ; META_WT="" ; META_FID=""
if [[ "${LOOP_SESSION_TAGGING:-0}" == "1" ]]; then
  META_USER="${LOOP_USER:-$(whoami 2>/dev/null || echo "unknown")}"
  META_WT="${LOOP_WORK_TYPE:-unknown}"
  META_FID="${LOOP_FEATURE_ID:-unknown}"

  # Auto-infer feature_id from branch name if not set
  if [[ "$META_FID" == "unknown" ]]; then
    BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
    META_FID=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1) || true
    [[ -z "$META_FID" ]] && META_FID="unknown"
  fi

  # Auto-infer work_type from branch name if not set
  if [[ "$META_WT" == "unknown" && -n "${BRANCH:-}" ]]; then
    case "$BRANCH" in
      *bugfix-*|*hotfix-*|*fix-*) META_WT="bugfix" ;;
      *feature-*|*feat-*) META_WT="feature" ;;
      *refactor-*|*cleanup-*) META_WT="refactor" ;;
      *docs-*|*doc-*) META_WT="docs" ;;
      *infra-*|*ci-*|*cli-*|*hook-*) META_WT="infra" ;;
    esac
  fi

  jq -n -c \
    --arg sid "$SESSION_ID" \
    --arg user "$META_USER" \
    --arg wt "$META_WT" \
    --arg fid "$META_FID" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{session_id: $sid, user: $user, work_type: $wt, feature_id: $fid, timestamp_created: $ts}' \
    > "$REPO_ROOT/.claude/memory/.session_metadata.json" 2>/dev/null || true
fi

# Log session_start event to JSONL
echo "$INPUT" | jq -c \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO_NAME" \
  --arg sid "$SESSION_ID" \
  --arg src "$SOURCE" \
  --arg mdl "$MODEL" \
  --arg mu "$META_USER" \
  --arg mwt "$META_WT" \
  --arg mfid "$META_FID" \
  '{
    v: 3,
    timestamp: $ts,
    repo: $repo,
    event: "session_start",
    source: (if $src == "" then "unknown" else $src end)
  } + (if $mdl != "" then {model: $mdl} else {} end)
    + (if $sid != "" then {session: $sid} else {} end)
    + (if $mu != "" then {user: $mu} else {} end)
    + (if $mwt != "" then {work_type: $mwt} else {} end)
    + (if $mfid != "" then {feature_id: $mfid} else {} end)' >> "$METRICS_FILE"

# OTEL setup: if endpoint configured AND CLAUDE_ENV_FILE exists, write OTEL env vars
if [[ -n "${LOOP_OTEL_ENDPOINT:-}" && -n "${CLAUDE_ENV_FILE:-}" ]]; then
  {
    echo "export CLAUDE_CODE_ENABLE_TELEMETRY=1"
    echo "export OTEL_METRICS_EXPORTER=otlp"
    echo "export OTEL_LOGS_EXPORTER=otlp"
    echo "export OTEL_EXPORTER_OTLP_ENDPOINT=$LOOP_OTEL_ENDPOINT"
  } >> "$CLAUDE_ENV_FILE"
fi

# Store session start timestamp for duration tracking (item #8)
date +%s > "$REPO_ROOT/.claude/memory/.session_start_epoch" 2>/dev/null || true

# Reset CL warning counter for new session
rm -f "$REPO_ROOT/.claude/memory/.cl_warning_count" 2>/dev/null || true

# CL maintenance: cleanup expired fingerprints + integrity check
CL_DB_SCRIPT="$REPO_ROOT/scripts/cl-db.sh"
if [[ -f "$CL_DB_SCRIPT" ]]; then
  (
    source "$CL_DB_SCRIPT"
    DB_FILE="$REPO_ROOT/.claude/memory/learnings.db"
    if [[ -f "$DB_FILE" ]]; then
      export CL_DB_PATH="$DB_FILE"
      cl_cleanup_expired 2>/dev/null || true
      cl_check_integrity 2>/dev/null || true
      cl_score_all 2>/dev/null || true
      cl_auto_suppress_low_quality 2>/dev/null || true
    fi
  )
fi

# Rotate old metrics on fresh startup (keeps 90 days, archives older)
if [[ "$SOURCE" == "startup" && -x "$REPO_ROOT/scripts/claude-metrics-rotate.sh" && "${LOOP_METRICS:-1}" != "0" ]]; then
  bash "$REPO_ROOT/scripts/claude-metrics-rotate.sh" 2>/dev/null || true
fi

# Recalibrate model routing cost rates (reads recent metrics to update per-token estimates)
if [[ "$SOURCE" == "startup" && -f "$REPO_ROOT/scripts/cl-model-router.sh" ]]; then
  (
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/cl-model-router.sh" 2>/dev/null || true
    cl_calibrate_on_startup 2>/dev/null || true
  )
fi

# Learnings sync check (opt-in)
SYNC_MSG=""
if [[ "${LOOP_SYNC_LEARNINGS:-0}" == "1" ]]; then
  SYNC_SCRIPT="$REPO_ROOT/scripts/sync-learnings.sh"
  # Also check relative to template dir for cross-repo invocations
  if [[ ! -x "$SYNC_SCRIPT" ]]; then
    for candidate in "${LOOP_TEMPLATE_DIR:-}" "$HOME/repos/claude-cli"; do
      if [[ -n "$candidate" && -x "$candidate/scripts/sync-learnings.sh" ]]; then
        SYNC_SCRIPT="$candidate/scripts/sync-learnings.sh"
        break
      fi
    done
  fi
  if [[ -x "$SYNC_SCRIPT" ]]; then
    UNSYNCED=$("$SYNC_SCRIPT" --check 2>/dev/null | tail -1) || true
    if [[ -n "$UNSYNCED" && "$UNSYNCED" != "0" ]]; then
      SYNC_MSG="$UNSYNCED unsynced learnings detected in local memory. Run /sync-learnings to review and migrate."
    fi
  fi
fi

# Return additionalContext for resumed sessions
CONTEXT_MSG=""
if [[ "$SOURCE" == "resume" ]]; then
  CONTEXT_MSG="Resumed session. Use /catchup to recover branch context."
fi

# Post-compaction: checkpoint content is already in the compaction summary
# (pre-compact.sh embeds it inline in additionalContext → captured by compaction).
# Only add a reminder to use /catchup for full git context if needed.
if [[ "$SOURCE" == "compact" ]]; then
  CONTEXT_MSG="Session resumed after compaction. Checkpoint state was preserved inline in the compaction summary. Use /catchup if you need full branch/commit context."
fi

# Append sync message if present
if [[ -n "$SYNC_MSG" ]]; then
  if [[ -n "$CONTEXT_MSG" ]]; then
    CONTEXT_MSG="$CONTEXT_MSG\n\n$SYNC_MSG"
  else
    CONTEXT_MSG="$SYNC_MSG"
  fi
fi

# Task checkpoint restore: inject task list if a fresh checkpoint exists
TASKS_CHECKPOINT_FILE="$REPO_ROOT/.claude/memory/tasks-checkpoint.json"
TASKS_CHECKPOINT_USED="$REPO_ROOT/.claude/memory/tasks-checkpoint.used.json"

if command -v jq >/dev/null 2>&1 && [[ -f "$TASKS_CHECKPOINT_FILE" ]]; then
  # Check the file is less than 24 hours old
  if find "$TASKS_CHECKPOINT_FILE" -mtime -1 2>/dev/null | grep -q .; then
    # Extract only pending and in_progress tasks
    TASKS_JSON=$(jq -c '[.[] | select(.status == "pending" or .status == "in_progress")]' \
      "$TASKS_CHECKPOINT_FILE" 2>/dev/null) || TASKS_JSON=""
    TASK_COUNT=$(echo "$TASKS_JSON" | jq 'length' 2>/dev/null) || TASK_COUNT=0
    if [[ -n "$TASKS_JSON" && "$TASK_COUNT" -gt 0 ]]; then
      TASK_RESTORE_MSG="TASK RESTORE: The following tasks were active before compaction. Call TaskCreate for each one that does not already exist (check with TaskList first). Only restore tasks with status \"pending\" or \"in_progress\":\n$TASKS_JSON"
      if [[ -n "$CONTEXT_MSG" ]]; then
        CONTEXT_MSG="$CONTEXT_MSG\n\n$TASK_RESTORE_MSG"
      else
        CONTEXT_MSG="$TASK_RESTORE_MSG"
      fi
    fi
    # Rename checkpoint to prevent double-restore on next session start without compaction
    mv "$TASKS_CHECKPOINT_FILE" "$TASKS_CHECKPOINT_USED" 2>/dev/null || true
  fi
fi

# Emit additionalContext if we have anything to say
if [[ -n "$CONTEXT_MSG" ]]; then
  echo "$CONTEXT_MSG" | jq -Rs '{ additionalContext: . }'
fi

exit 0
