#!/usr/bin/env bash
# Cross-platform notification script for Claude Code hooks.
# All output goes to /dev/null — nothing ever hits stdout/stderr.
# This prevents "JSON validation failed" errors from hook stdout parsing.
# path-safety: no-euo — notification hook; must not exit non-zero on missing tools
#
# Usage: notify.sh <subtitle> <message> [sound]
# sound: macOS sound name (Glass, Blow, Basso, etc.) or empty for silent
# On Linux, uses notify-send (sound arg ignored).

exec >/dev/null 2>&1

SUBTITLE="${1:-Notification}"
MESSAGE="${2:-Claude Code}"
SOUND="${3:-Glass}"

if [[ "$OSTYPE" == darwin* ]]; then
  # Skip sound if Terminal is frontmost (avoids noise when actively watching)
  FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
  if [ "$FRONTMOST" = "Terminal" ]; then
    SOUND=""
  fi

  # Escape double-quotes for osascript interpolation
  MESSAGE="${MESSAGE//\"/\\\"}"
  SUBTITLE="${SUBTITLE//\"/\\\"}"

  # Use terminal-notifier if available, fall back to osascript
  if command -v terminal-notifier >/dev/null 2>&1; then
    SOUND_FLAG=()
    if [ -n "$SOUND" ]; then
      SOUND_FLAG=(-sound "$SOUND")
    fi
    terminal-notifier \
      -title "Claude Code" \
      -subtitle "$SUBTITLE" \
      -message "$MESSAGE" \
      "${SOUND_FLAG[@]}" \
      -timeout 10 \
      2>/dev/null || true
  else
    osascript -e "display notification \"$MESSAGE\" with title \"Claude Code\" subtitle \"$SUBTITLE\"" 2>/dev/null || true
    if [ -n "$SOUND" ]; then
      afplay "/System/Library/Sounds/${SOUND}.aiff" 2>/dev/null &
    fi
  fi
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "Claude Code — $SUBTITLE" "$MESSAGE" 2>/dev/null || true
fi
