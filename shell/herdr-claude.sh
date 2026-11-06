#!/bin/sh
# Opens a new Herdr tab, starts Claude Code there and submits one prompt:
# the dictation on stdin (may be empty), a blank line, then the selected text.
# HERDR_BIN names the herdr-app binary, HERDR_CLAUDE_CWD the new tab's directory.
set -u
herdr=${HERDR_BIN:-herdr-app}
dictation=$(cat)
# Why: voice-switch's window may hold focus; the selection lives in the app the dictation was for.
[ -z "${VOICE_SWITCH_APP:-}" ] || open -b "$VOICE_SWITCH_APP"
old=$(pbpaste)
printf '' | pbcopy
# Why: the delay lets the hotkey's ctrl+cmd come up, or the copy arrives as ctrl+cmd+c.
osascript -e 'delay 0.3' -e 'tell application "System Events" to keystroke "c" using command down'
sleep 0.2
selection=$(pbpaste)
printf '%s' "$old" | pbcopy
if [ -n "$dictation" ] && [ -n "$selection" ]; then
  prompt=$(printf '%s\n\n%s' "$dictation" "$selection")
else
  prompt=$dictation$selection
fi
[ -n "$prompt" ] || { echo "herdr-claude: nothing copied or said" >&2; exit 3; }

# Why: keypipe's onFail.output would get only the dictation, so the whole prompt is saved here.
fail() {
  printf '%s' "$prompt" | pbcopy
  echo "herdr-claude: $1; prompt copied to the clipboard" >&2
  exit 1
}

# Why: without --folder the tab opens in the focused terminal's folder, one Claude Code already
# trusts; an untrusted one stops the first message at Claude's trust prompt.
out=$("$herdr" do tab.new --name claude --argv '["claude"]' --task "$prompt" \
  ${HERDR_CLAUDE_CWD:+--folder "$HERDR_CLAUDE_CWD"} 2>&1) ||
  fail "tab.new failed: $(printf '%s' "$out" | tr -s '\n\t ' ' ')"
