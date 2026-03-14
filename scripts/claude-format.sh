#!/usr/bin/env bash
# PostToolUse formatter for Swift/iOS repos. # path-safety: no-euo — PostToolUse formatter; must exit 0 even when formatter is absent
# Receives hook event data via stdin (JSON). Formats the edited file.
# Looks for SwiftFormat in Pods (CocoaPods), then system PATH.

FILE_PATH=$(cat | jq -r '.tool_input.file_path // empty')
[[ "$FILE_PATH" == *.swift ]] || exit 0

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Check CocoaPods installation first (common in iOS projects)
if [ -x "$REPO_ROOT/Pods/SwiftFormat/CommandLineTool/swiftformat" ]; then
  "$REPO_ROOT/Pods/SwiftFormat/CommandLineTool/swiftformat" "$FILE_PATH" 2>/dev/null
elif command -v swiftformat >/dev/null 2>&1; then
  swiftformat "$FILE_PATH" 2>/dev/null
fi

exit 0
