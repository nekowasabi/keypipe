#!/bin/sh
# Prints the prompt for one send: the dictation on stdin (may be empty), a blank line, then the text
# selected in the front app. The selection is copied with Cmd+C through the clipboard, which is put
# back afterwards. Exit 3: nothing said or selected. Exit 1: the copy failed (the dictation, if any,
# is left on the clipboard). Shared by herdr-claude.sh and the grokbot rule.
set -u
dictation=$(cat)

# Why: two fires borrow the one clipboard; without the lock the second saves the first's empty
# clipboard as the "old" one, or copies before the first restores it. A run killed mid-copy
# leaves the lock behind, so after about 10 s it is taken over.
lock=${TMPDIR:-/tmp}/keypipe-selection-prompt.lock
waited=0
until mkdir "$lock" 2>/dev/null; do
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || { rmdir "$lock" 2>/dev/null; waited=0; }
  sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

# Why: voice-switch's window may hold focus; the selection lives in the app the dictation was for.
[ -z "${VOICE_SWITCH_APP:-}" ] || open -b "$VOICE_SWITCH_APP"
# Why: the x keeps trailing newlines that $(...) would drop.
old=$(pbpaste; printf x)
old=${old%x}
printf '' | pbcopy
# Why: the delay lets the hotkey's ctrl+cmd come up, or the copy arrives as ctrl+cmd+c.
osascript -e 'delay 0.3' -e 'tell application "System Events" to keystroke "c" using command down'
copied=$?
sleep 0.2
selection=$(pbpaste)
printf '%s' "$old" | pbcopy

if [ "$copied" != 0 ]; then
  reason="could not copy the selection (osascript exit $copied; Accessibility for System Events?)"
  if [ -n "$dictation" ]; then
    printf '%s' "$dictation" | pbcopy
    reason="dictation copied to the clipboard; $reason"
  fi
  echo "selection-prompt: $reason" >&2
  exit 1
fi
if [ -n "$dictation" ] && [ -n "$selection" ]; then
  printf '%s\n\n%s' "$dictation" "$selection"
elif [ -n "$dictation$selection" ]; then
  printf '%s' "$dictation$selection"
else
  echo "selection-prompt: nothing copied or said" >&2
  exit 3
fi
