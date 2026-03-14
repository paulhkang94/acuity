#!/usr/bin/env bash
# auto-activate.sh — UserPromptSubmit hook for context-aware skill/command suggestion
#
# Concept inspired by diet103/claude-code-infrastructure-showcase (MIT, 8.8K stars)
# https://github.com/diet103/claude-code-infrastructure-showcase
# Adapted and rebuilt for standardized template infrastructure.
#
# How it works:
#   1. Reads the user's prompt from stdin (JSON with .prompt field)
#   2. Matches keywords against available skills, commands, and agents
#   3. Returns additionalContext with relevant suggestions
#
# Install: Add to settings.json under "UserPromptSubmit" hook event
# Input: JSON on stdin with { "prompt": "...", "cwd": "...", ... }
# Output: JSON with { "additionalContext": "..." } or silent exit 0
#
# Design: Organic/minimal. No config files. Keyword matching only.
# Grows with the codebase — add new patterns as skills/commands are added.

set -euo pipefail

# Opt-out: set LOOP_AUTO_ACTIVATE=0 to disable all auto-activate suggestions
[[ "${LOOP_AUTO_ACTIVATE:-1}" == "0" ]] && exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || exit 0

# Bail fast if prompt is empty or very short
[[ ${#PROMPT} -lt 5 ]] && exit 0

# --- Session ID bridge (first-party → file) ---
# Claude Code provides session_id in hook stdin JSON. We write it to a file
# so non-hook scripts (verify, benchmark) can read it for session correlation.
SESSION_FILE=".claude/memory/.session_id"
NATIVE_SID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || NATIVE_SID=""
if [[ -n "$NATIVE_SID" && -d ".claude/memory" ]]; then
  echo "$NATIVE_SID" > "$SESSION_FILE" 2>/dev/null || true
fi

# Lowercase for matching
PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

SUGGESTIONS=""

# --- Infrastructure integrity check (runs once per session, fast) ---
# Warns if critical infrastructure files are missing on the current branch.
LOOP_CRITICAL_FILES=(
    "scripts/claude-verify.sh"
    "scripts/claude-log-failure.sh"
    "scripts/claude-log-subagent.sh"
    ".claude/skills/push-and-watch.md"
)
# Also check claude-test.sh as alternative to claude-verify.sh
MISSING_FILES=()
for f in "${LOOP_CRITICAL_FILES[@]}"; do
    if [[ "$f" == "scripts/claude-verify.sh" ]]; then
        [[ ! -f "$f" && ! -f "scripts/claude-test.sh" ]] && MISSING_FILES+=("$f")
    else
        [[ ! -f "$f" ]] && MISSING_FILES+=("$f")
    fi
done
if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    SUGGESTIONS="${SUGGESTIONS}WARNING: Template infrastructure incomplete — missing ${#MISSING_FILES[@]} file(s): ${MISSING_FILES[*]}. This branch may have been created before infrastructure was merged. Fix: merge the infra branch or cherry-pick the missing files.\n"
fi

# --- Tool availability checks (language-specific) ---
# Detect language from formatter and check required tools.
# Repos customize this block during setup.sh installation.
if [[ -f "settings.gradle" ]] || [[ -f "settings.gradle.kts" ]]; then
    # Kotlin/Android
    if ! command -v ktlint >/dev/null 2>&1; then
        SUGGESTIONS="${SUGGESTIONS}WARNING: ktlint not in PATH — auto-formatting disabled. Install: brew install ktlint\n"
    fi
elif [[ -f "Package.swift" ]] || [[ -f "Podfile" ]]; then
    # Swift/iOS
    if [[ -d "Pods/SwiftFormat" ]] && [[ ! -x "Pods/SwiftFormat/CommandLineTool/swiftformat" ]]; then
        SUGGESTIONS="${SUGGESTIONS}WARNING: SwiftFormat not found in Pods — run: bundle exec pod install\n"
    fi
elif [[ -f "pyproject.toml" ]] || [[ -f "poetry.lock" ]]; then
    # Python
    if ! command -v poetry >/dev/null 2>&1 && ! command -v ruff >/dev/null 2>&1; then
        SUGGESTIONS="${SUGGESTIONS}WARNING: poetry/ruff not in PATH — formatting and tests disabled. Install: pip install poetry ruff\n"
    fi
elif [[ -f "go.mod" ]]; then
    # Go
    if ! command -v go >/dev/null 2>&1; then
        SUGGESTIONS="${SUGGESTIONS}WARNING: go not in PATH. Install from https://go.dev/dl/\n"
    fi
elif [[ -f "package.json" ]]; then
    # TypeScript/JavaScript
    if ! command -v yarn >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
        SUGGESTIONS="${SUGGESTIONS}WARNING: yarn/npm not in PATH — builds disabled. Install Node.js + yarn\n"
    fi
fi

# --- Command suggestions ---

# /push-and-watch: pushing, CI, pipeline, MR
if echo "$PROMPT_LOWER" | grep -qE 'push|pipeline|ci\b|merge request|mr\b|gitlab'; then
    if [[ -f ".claude/skills/push-and-watch.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /push-and-watch to push and auto-monitor CI pipeline.\n"
    fi
fi

# /pre-mr: ready to submit, final check, before MR
if echo "$PROMPT_LOWER" | grep -qE 'pre.?mr|ready to submit|final check|before (mr|merge)|ship it'; then
    if [[ -f ".claude/skills/pre-mr.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /pre-mr for full pre-merge verification.\n"
    fi
fi

# /catchup: context, what happened, branch state, catch up
if echo "$PROMPT_LOWER" | grep -qE 'catch.?up|what happened|branch state|context|where (was|were|did) (i|we)'; then
    if [[ -f ".claude/skills/catchup.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /catchup to get up to speed on this branch.\n"
    fi
fi

# --- Skill suggestions ---

# Database migration
if echo "$PROMPT_LOWER" | grep -qE 'migrat|alembic|schema|database|db\b|table'; then
    if [[ -f ".claude/skills/db-migration.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /db-migration skill for database migration workflow.\n"
    elif [[ -f ".claude/skills/contentful-page-type-changes.md" ]] && echo "$PROMPT_LOWER" | grep -qE 'contentful|page.?type|cms'; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /contentful-page-type-changes skill.\n"
    fi
fi

# Async migration
if echo "$PROMPT_LOWER" | grep -qE 'async|modernize|plumb'; then
    if [[ -f ".claude/skills/modernize-async.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /modernize-async or /plumb-async for async migration workflow.\n"
    fi
fi

# QA/Playwright
if echo "$PROMPT_LOWER" | grep -qE 'playwright|e2e|qa\b|end.to.end|visual test|screenshot'; then
    if [[ -f ".claude/skills/qa-with-playwright.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /qa-with-playwright skill for E2E testing.\n"
    fi
fi

# --- Agent suggestions ---

# Code review
if echo "$PROMPT_LOWER" | grep -qE 'review|code.?review|feedback|check (my|this|the) (code|changes|diff)'; then
    if [[ -f ".claude/agents/code-reviewer.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: code-reviewer agent available at .claude/agents/code-reviewer.md\n"
    fi
fi

# MR creation
if echo "$PROMPT_LOWER" | grep -qE 'create.*(mr|merge)|mr.*create|open.*(mr|merge)'; then
    if [[ -f ".claude/agents/mr-creator.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: mr-creator agent available at .claude/agents/mr-creator.md\n"
    fi
fi

# --- Learnings sync ---

# Sync learnings keyword trigger
if echo "$PROMPT_LOWER" | grep -qE 'sync.?learn|retro.*learn|migrate.*learn|gotcha'; then
    SUGGESTIONS="${SUGGESTIONS}Tip: /sync-learnings checks for local learnings not yet in the shared template.\n"
fi

# Domain-specific learnings suggestions
if echo "$PROMPT_LOWER" | grep -qE 'swiftui|wkwebview|nswindow|macos|\.app.bundle|run.?loop'; then
    if [[ -f "docs/learnings/macos-desktop.md" ]] || [[ -f "${LOOP_TEMPLATE_DIR:-}/docs/learnings/macos-desktop.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}See docs/learnings/macos-desktop.md for macOS desktop gotchas.\n"
    fi
fi
if echo "$PROMPT_LOWER" | grep -qE 'dark.?mode|css|theme|color.?scheme|prefers.color'; then
    if [[ -f "docs/learnings/css-theming.md" ]] || [[ -f "${LOOP_TEMPLATE_DIR:-}/docs/learnings/css-theming.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}See docs/learnings/css-theming.md for CSS/theming gotchas.\n"
    fi
fi
if echo "$PROMPT_LOWER" | grep -qE 'golden|screenshot.?test|visual.?regress|lint.?gate'; then
    if [[ -f "docs/learnings/testing.md" ]] || [[ -f "${LOOP_TEMPLATE_DIR:-}/docs/learnings/testing.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}See docs/learnings/testing.md for testing/golden file gotchas.\n"
    fi
fi
if echo "$PROMPT_LOWER" | grep -qE 'parallel.?bash|edit.?tool|compaction|context.?window|subagent'; then
    if [[ -f "docs/learnings/claude-code.md" ]] || [[ -f "${LOOP_TEMPLATE_DIR:-}/docs/learnings/claude-code.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}See docs/learnings/claude-code.md for Claude Code gotchas.\n"
    fi
fi
if echo "$PROMPT_LOWER" | grep -qE 'ruff|typer|fastmcp|python.?builtin|click.?command'; then
    if [[ -f "docs/learnings/python.md" ]] || [[ -f "${LOOP_TEMPLATE_DIR:-}/docs/learnings/python.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}See docs/learnings/python.md for Python gotchas.\n"
    fi
fi

# --- Guiding principles reminder ---

# Standardization or principles discussion
if echo "$PROMPT_LOWER" | grep -qE 'principle|standardiz|deviat|why (do|should|are) we'; then
    SUGGESTIONS="${SUGGESTIONS}Reference: Guiding principles at docs/GUIDING-PRINCIPLES.md — 6 principles for AI-assisted development. Standardization rationale at docs/WHY-STANDARDIZATION.md.\n"
fi

# --- Infrastructure drift warning ---

# Editing template-managed files
if echo "$PROMPT_LOWER" | grep -qE 'edit.*(log.?failure|log.?subagent|catchup|pre.?mr)|modify.*(hook|settings\.json|guard)|change.*(infra|infrastructure|cli)'; then
    SUGGESTIONS="${SUGGESTIONS}Warning: Template-managed files should be updated via the template's scripts/upgrade-repo.sh, not edited directly. Run detect-drift.sh to check consistency.\n"
fi

# --- Context enrichment ---

# Failure patterns: if prompt mentions an error or failure
if echo "$PROMPT_LOWER" | grep -qE 'error|fail|broken|crash|bug|fix|debug|issue|wrong|doesn.t work'; then
    if [[ -f ".claude/memory/failure-patterns.md" ]]; then
        PATTERN_COUNT=$(grep -c '^## \[' ".claude/memory/failure-patterns.md" 2>/dev/null || echo "0")
        if [[ "$PATTERN_COUNT" -gt 0 ]]; then
            SUGGESTIONS="${SUGGESTIONS}Note: $PATTERN_COUNT failure patterns available in .claude/memory/failure-patterns.md — check for known fixes before debugging.\n"
        fi
    fi
fi

# --- Pattern detection: recurring errors trigger meta-analysis suggestion ---
# Opt-out: set LOOP_PATTERN_DETECTION=0 to disable pattern detection suggestions
# Session-length threshold: skip for short sessions (fewer than 10 tool events)

if [[ "${LOOP_PATTERN_DETECTION:-1}" != "0" ]] && echo "$PROMPT_LOWER" | grep -qE 'error|fail|broken|crash|bug|fix|debug|again|keeps? (happening|failing|breaking)|same (error|issue|problem)|recurring|repeat'; then
    if [[ -f "scripts/claude-pattern-detector.sh" ]] && [[ -f ".claude/memory/metrics.jsonl" ]]; then
        # Session-length threshold: don't suggest pattern analysis for short/simple sessions
        EVENT_COUNT=$(wc -l < ".claude/memory/metrics.jsonl" 2>/dev/null | tr -d ' ')
        if [[ "${EVENT_COUNT:-0}" -ge 10 ]]; then
            # Quick check: do recent metrics show recurring patterns?
            if scripts/claude-pattern-detector.sh --check-recent --window 15 --threshold 3 --quiet . >/dev/null 2>&1; then
                : # No recurring patterns, nothing to suggest
            else
                SUGGESTIONS="${SUGGESTIONS}Meta: Recurring error patterns detected in recent metrics. Run \`scripts/claude-pattern-detector.sh --analyze .\` for full report, or \`--draft-patterns\` to auto-draft failure-pattern entries. (To disable: export LOOP_PATTERN_DETECTION=0)\n"
            fi
        fi
    fi
fi

# Build performance: benchmark, build time, slow build, performance
if echo "$PROMPT_LOWER" | grep -qE 'benchmark|build.?time|slow.?build|build.?perf|gradle.?slow|compile.?time'; then
    if [[ -f "scripts/claude-build-benchmark.sh" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use scripts/claude-build-benchmark.sh to capture build timing. Use scripts/claude-build-report.sh --compare \"before\" \"after\" for A/B comparison.\n"
    fi
fi

# /compare-design: design, figma, screenshot, visual
if echo "$PROMPT_LOWER" | grep -qE 'design|figma|screenshot|visual|compare.*design|pixel|mockup|ui.?review'; then
    if [[ -f ".claude/skills/compare-design.md" ]]; then
        SUGGESTIONS="${SUGGESTIONS}Tip: Use /compare-design to screenshot and compare against Figma designs.\n"
    fi
fi

# --- Compaction prediction heuristic (item #4) ---
# Track event count per session; suggest proactive compaction when high.
COMPACTION_THRESHOLD="${LOOP_COMPACTION_THRESHOLD:-50}"
if [[ -f ".claude/memory/metrics.jsonl" ]]; then
    # Count events in current session (since last session_start)
    LAST_START_LINE=$(grep -n '"session_start"' ".claude/memory/metrics.jsonl" 2>/dev/null | tail -1 | cut -d: -f1)
    if [[ -n "$LAST_START_LINE" ]]; then
        TOTAL_LINES=$(wc -l < ".claude/memory/metrics.jsonl" | tr -d ' ')
        SESSION_EVENT_COUNT=$((TOTAL_LINES - LAST_START_LINE))
        if [[ "$SESSION_EVENT_COUNT" -ge "$COMPACTION_THRESHOLD" ]]; then
            SUGGESTIONS="${SUGGESTIONS}Performance: ${SESSION_EVENT_COUNT} tool events in this session (threshold: ${COMPACTION_THRESHOLD}). Consider running /compact to free context window before it auto-compacts at a less ideal time.\n"
        fi
    fi
fi

# --- Output ---

if [[ -n "$SUGGESTIONS" ]]; then
    # Use jq to properly escape the suggestions string
    echo "$SUGGESTIONS" | jq -Rs '{ additionalContext: . }'
else
    exit 0
fi
