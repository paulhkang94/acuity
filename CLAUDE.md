# Acuity — Claude Code Guide

## LOOP Workflow (Follow This for Every Code Change)

When making code changes, **always** follow this cycle:

```
1. Edit → 2. Format (auto) → 3. Verify → 4. Fix if needed → [Loop until green]
```

### Step 1: Edit Code
- Use `Edit` or `Write` tools to modify source files
- PostToolUse hook auto-runs `scripts/claude-format.sh` after every edit

### Step 2: Verify
Run the verification script at the appropriate tier:
```bash
# Fast check (lint/compile only)
scripts/claude-verify.sh --lint

# Run tests for changed files
scripts/claude-verify.sh --test <file_or_target>

# Full pipeline (lint → test → typecheck/compile)
scripts/claude-verify.sh --all
```

### Step 3: Parse & Fix
- If tests pass: continue to next task or commit
- If tests fail: read the error, fix the code, go back to Step 1
- Only report completion when tests pass

### Key Rules
- Always run verification after non-trivial changes
- Use targeted tests first (fast feedback), full suite before MR
- Never skip the test step for non-trivial changes
- **Never pause to ask "what next?"** — after completing a task, check TaskList for the next unblocked item and continue autonomously. Only stop when the queue is empty or a decision genuinely requires user judgment.
- **Parallelize independent tasks** — scan the queue for tasks with no shared dependencies and run them concurrently via parallel tool calls or background agents.
- **Background-thread long tasks** — any operation >5s that doesn't need its output immediately goes to `run_in_background` (Bash) or a background Task agent. This keeps the main thread responsive to user input. Examples: dependency installs, full test suites, research agents, browser downloads, build+test chains.

### Markdown Preview
- **MarkView** (recommended OSS): Native macOS app with live preview, file watching, and MCP integration for AI workflows. Install via `brew install --cask paulhkang94/markview/markview`, then use `mdpreview file.md` or Cmd+Space to open files. Supports MCP for direct AI integration.
- **Quick Look**: Select `.md` file in Finder → press Space (macOS built-in or via QLMarkdown)
- **VS Code**: Open `.md` file → Cmd+Shift+V for preview, or Cmd+K V for side-by-side

## Plan Mode First (Multi-File Changes)

For changes that touch 3+ files or involve architectural decisions:
1. **Start in plan mode** — think through the approach before writing code
2. Identify all files that need changes and their dependencies
3. Consider edge cases and test coverage
4. Execute the plan, verifying after each file change
5. Run `scripts/claude-verify.sh --all` before committing

> "Plan mode prevents the #1 failure mode: partial multi-file changes that leave the codebase in an inconsistent state."

## Project Structure

```
Sources/acuity/
  Commands/   — CLI command structs (ArgumentParser); register in ExtraDisplay.swift
  DDC/        — DDCController, IOAVServiceBridge, VCPCode
  Display/    — PlistWriter, ResolutionEncoder, ResolutionPresets, DisplayEnumerator
  Daemon/     — ReconfigurationWatcher, AgentManager
  Menubar/    — StatusMenuController, BrightnessSliderView, DisplayMenuItem
  HID/        — BrightnessKeyInterceptor
  OSD/        — BezelOverlay
Tests/acuityTests/  — XCTest (19 tests)
pytests/                  — pytest (9 tests, covers scripts/hidpi.py)
scripts/                  — install.sh, uninstall.sh, hidpi.py, claude-verify.sh
mcp/                      — MCP server (server.py + config_example.json)
LaunchAgent/              — com.acuity.agent.plist
```

## Testing
- Swift: `swift test`
- Python: `python3 -m pytest pytests/ -q`
- Full pipeline: `scripts/claude-verify.sh --all`
- Single test: `swift test --filter ClassName/methodName`

## Build
- `swift build -c release` → `.build/release/acuity`
- Install system-wide: `sudo bash scripts/install.sh`

## Rules
- Never edit `.build/` generated files
- Run `scripts/claude-verify.sh --all` before every commit
- New CLI commands: add to `Sources/acuity/Commands/` and register in `ExtraDisplay.swift`
- DDC requires physical monitors — abstract behind `protocol DDCControlling`; inject mock in tests
- `BezelServices` and `IOAVService`: load via `dlopen`/`dlsym` only, never link directly
- `acuity start` runs NSApplication in `.accessory` mode; call `setsid()` before `NSApplication.shared.run()` to detach from terminal

## Gotchas

Repo-specific pitfalls, API quirks, and configuration gotchas go in `docs/GOTCHAS.md`. When you discover a gotcha during development, append it there with date, context, and the specific pitfall. Cross-repo patterns that apply universally go to the shared template learnings instead.

## Agent Output Convention

When spawning Task agents:
1. Write durable results (research, specs, designs) to `docs/personal/` or `docs/research/` (git-tracked)
2. Write ephemeral results (scan results, audit snapshots, changelogs) to `.claude/memory/agents/`
3. Return only a 2-3 line summary to main context
4. Include output file path in the summary so results are recoverable
5. Rule of thumb: if you'd be upset losing it, it belongs in `docs/`, not `.claude/memory/agents/`

## Action Item Extraction

Any agent output or workflow step that produces findings, recommendations, or TODOs must include an **action item extraction pass** before returning to the user:

1. **Extract**: Scan the output for implicit/explicit action items (bugs to fix, features to add, follow-ups, decisions needed)
2. **Structure**: Present proposed items in a table: `| Priority | Title | Scope | Complexity |`
3. **Review**: Let the user edit/approve/reject before queueing. Never auto-queue without review.

## Compact Instructions

When compacting, preserve:
- **Task list state (CRITICAL)**: If TaskList has items, enumerate EACH with: ID, subject, status, blockedBy. Task state is in-memory only and will be LOST if not included in the compaction summary. Use TaskList to retrieve current state before compacting.
- File paths that were modified and why
- Key decisions made during the session
- Agent/subagent results and what they accomplished
- Any errors or blockers encountered

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/catchup` | Summarize branch state for context recovery |
| `/pre-mr` | Full pre-merge readiness checklist |
<!-- TODO: Add repo-specific commands -->
