#!/bin/sh
# Opens a new Herdr tab, starts Claude Code there and submits one prompt:
# the dictation on stdin (may be empty), a blank line, then the selected text.
# HERDR_BIN names the herdr binary, HERDR_CLAUDE_CWD the new tab's directory.
set -u
herdr=${HERDR_BIN:-herdr}
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

# Why: without --cwd the tab opens in the focused workspace, a folder Claude Code already trusts;
# an untrusted one stops agent start at Claude's trust prompt.
json=$("$herdr" tab create --focus --label claude ${HERDR_CLAUDE_CWD:+--cwd "$HERDR_CLAUDE_CWD"}) ||
  fail "tab create failed"
pane=$(printf '%s' "$json" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')
[ -n "$pane" ] || fail "no pane_id in: $json"
# Why: agent names allow only [a-z0-9_-], and pane ids carry ':' and capitals.
name=claude-$(date +%s)
# Why: the new pane's shell is still starting, and agent start refuses it as agent_pane_busy.
tries=0
until out=$("$herdr" agent start "$name" --kind claude --pane "$pane" 2>&1); do
  tries=$((tries + 1))
  case $out in *agent_pane_busy*) [ "$tries" -lt 20 ] && sleep 0.5 && continue ;; esac
  fail "agent start failed in $pane: $out"
done
"$herdr" agent prompt "$pane" "$prompt" >/dev/null || fail "agent prompt failed in $pane"
