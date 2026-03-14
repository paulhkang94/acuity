#!/usr/bin/env bash
# PostToolUseFailure hook: Log tool failures to metrics JSONL.
# Receives hook event data via stdin (JSON).
# Appends a single JSONL line to .claude/memory/metrics.jsonl
#
# v3: Universal — auto-detects repo name, mkdir -p, empty string handling.
# Requires: jq (exits gracefully if missing)

set -euo pipefail

# Source version constants
source "$(dirname "$0")/cl-version.sh" 2>/dev/null || { CL_JSONL_VERSION=3; CL_SUBAGENT_JSONL_VERSION=4; CL_DB_SCHEMA_VERSION=3; }

# Opt-out: set LOOP_METRICS=0 or LOOP_METRICS_TOOL_FAILURES=0 to disable
[[ "${LOOP_METRICS:-1}" == "0" || "${LOOP_METRICS_TOOL_FAILURES:-1}" == "0" ]] && exit 0

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
  --argjson v "$CL_JSONL_VERSION" \
  '{
    v: $v,
    timestamp: $ts,
    repo: $repo,
    event: "tool_failure",
    tool: ((.tool_name // "unknown") | if . == "" then "unknown" else . end),
    file: ((.tool_input.file_path // .tool_input.command // "unknown") | if . == "" then "unknown" else . end | .[0:200]),
    error: ((.error // "unknown") | if . == "" then "unknown" else . end | .[0:500]),
    is_interrupt: (.is_interrupt // false)
  } + (if $sid != "" then {session: $sid} else {} end)
    + (if $mu != "" then {user: $mu} else {} end)
    + (if $mwt != "" then {work_type: $mwt} else {} end)
    + (if $mfid != "" then {feature_id: $mfid} else {} end)' >> "$METRICS_FILE"

# --- Pattern detection: check if this error recurs in recent events ---
# Opt-out: set LOOP_PATTERN_DETECTION=0 to disable
if [[ "${LOOP_PATTERN_DETECTION:-1}" != "0" ]]; then
  # Extract error signature: first 80 chars of the error field
  ERROR_SIG=$(echo "$INPUT" | jq -r '(.error // "")[0:80]' 2>/dev/null) || ERROR_SIG=""
  if [[ -n "$ERROR_SIG" && "$ERROR_SIG" != "null" ]]; then
    # Count occurrences of this signature in the last 10 events
    SIG_COUNT=$(tail -n 10 "$METRICS_FILE" | jq -r --arg sig "$ERROR_SIG" \
      'select(.event == "tool_failure") | select((.error // "")[0:80] == $sig) | .error' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$SIG_COUNT" -ge 2 ]]; then
      echo '{"additionalContext":"This error has occurred '"$SIG_COUNT"' times recently. Check .claude/memory/failure-patterns.md for known fixes, or run scripts/claude-pattern-detector.sh --analyze . for full analysis."}'
    fi
  fi
fi

# --- CL Fingerprint Auto-Extraction ---
# Opt-out: set LOOP_FINGERPRINTING=0 to disable
if [[ "${LOOP_FINGERPRINTING:-1}" != "0" ]]; then
  DB_PATH="$REPO_ROOT/.claude/memory/learnings.db"

  # Skip if no DB (CL not initialized) or sqlite3 missing
  if [[ -f "$DB_PATH" ]] && command -v sqlite3 &>/dev/null && sqlite3 "$DB_PATH" "SELECT 1;" &>/dev/null 2>&1; then
    # Skip interrupts — they're not real errors
    IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null) || IS_INTERRUPT="false"
    if [[ "$IS_INTERRUPT" != "true" ]]; then
      FP_TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || FP_TOOL=""
      FP_ERROR=$(echo "$INPUT" | jq -r '.error // ""' 2>/dev/null | head -c 200) || FP_ERROR=""
      FP_CMD=$(echo "$INPUT" | jq -r '(.tool_input.command // .tool_input.file_path // "")' 2>/dev/null | head -c 200) || FP_CMD=""

      if [[ -n "$FP_ERROR" && "$FP_ERROR" != "null" ]]; then
        # Source cl-db.sh for keyword extraction
        CL_DB_SCRIPT="$REPO_ROOT/scripts/cl-db.sh"
        [[ ! -f "$CL_DB_SCRIPT" ]] && CL_DB_SCRIPT="$(dirname "$0")/cl-db.sh"

        if [[ -f "$CL_DB_SCRIPT" ]]; then
          source "$CL_DB_SCRIPT"
          export CL_DB_PATH="$DB_PATH"

          # Extract keywords from error + command/file
          FP_KEYWORDS=$(cl_extract_keywords "$FP_ERROR $FP_CMD")

          if [[ -n "$FP_KEYWORDS" ]]; then
            # Dedup: FTS AND-query on top 5 keywords
            FP_TOP=$(echo "$FP_KEYWORDS" | tr ' ' '\n' | head -5 | tr '\n' ' ')
            FP_FTS=""
            for kw in $FP_TOP; do
              kw_esc=$(echo "$kw" | sed "s/'/''/g")
              FP_FTS="${FP_FTS:+$FP_FTS AND }\"$kw_esc\""
            done

            FP_EXISTING=0
            if [[ -n "$FP_FTS" ]]; then
              FP_EXISTING=$(sqlite3 "$DB_PATH" "
                SELECT COUNT(*) FROM fingerprints f
                JOIN fingerprints_fts fts ON f.id = fts.rowid
                WHERE fingerprints_fts MATCH '$FP_FTS';
              " 2>/dev/null || echo "0")
            fi

            # Hard cap: max 50 auto-extracted (prevents unbounded growth)
            FP_AUTO_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM fingerprints WHERE source='failure_hook';" 2>/dev/null || echo "0")

            if [[ "$FP_EXISTING" -eq 0 && "$FP_AUTO_COUNT" -lt 50 ]]; then
              # Generalize: replace paths with /... and numbers with N
              FP_GENERAL=$(echo "$FP_ERROR" | head -1 | sed 's|/[^ ]*|/...|g; s/[0-9]\+/N/g' | head -c 200)
              FP_RESOLUTION="Investigation needed: $FP_GENERAL"

              # 90-day expiry for auto-extracted
              FP_EXPIRY=$(date -u -v+90d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+90 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

              FP_KW_ESC=$(echo "$FP_KEYWORDS" | sed "s/'/''/g")
              FP_GEN_ESC=$(echo "$FP_GENERAL" | sed "s/'/''/g")
              FP_RES_ESC=$(echo "$FP_RESOLUTION" | sed "s/'/''/g")
              FP_TOOL_ESC=$(echo "$FP_TOOL" | sed "s/'/''/g")

              sqlite3 "$DB_PATH" "
                INSERT INTO fingerprints (tool, keywords, error_pattern, resolution, resolution_type, source, expires_at)
                VALUES ('$FP_TOOL_ESC', '$FP_KW_ESC', '$FP_GEN_ESC', '$FP_RES_ESC', 'investigation', 'failure_hook', $(if [[ -n "$FP_EXPIRY" ]]; then echo "'$FP_EXPIRY'"; else echo "NULL"; fi));
              " 2>/dev/null || true
            fi

            # --- Miss tracking: check if a curated fingerprint should have caught this ---
            # Use OR query (broader than dedup AND query) to find curated fingerprints
            # that are semantically related to this failure
            FP_OR_FTS=""
            for kw in $FP_TOP; do
              kw_esc=$(echo "$kw" | sed "s/'/''/g")
              FP_OR_FTS="${FP_OR_FTS:+$FP_OR_FTS OR }\"$kw_esc\""
            done
            if [[ -n "$FP_OR_FTS" ]]; then
              FP_CURATED=$(sqlite3 "$DB_PATH" "
                SELECT f.id FROM fingerprints f
                JOIN fingerprints_fts fts ON f.id = fts.rowid
                WHERE fingerprints_fts MATCH '$FP_OR_FTS'
                  AND f.source != 'failure_hook'
                  AND f.suppressed = 0
                ORDER BY bm25(fingerprints_fts)
                LIMIT 1;
              " 2>/dev/null || true)

              if [[ -n "$FP_CURATED" ]]; then
                sqlite3 "$DB_PATH" "
                  UPDATE fingerprints SET times_missed = times_missed + 1,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                  WHERE id = $FP_CURATED;
                " 2>/dev/null || true
              fi
            fi
          fi
        fi
      fi
    fi
  fi
fi

exit 0
