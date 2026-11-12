#!/bin/sh
# Opens a new Herdr tab, starts Claude Code there and submits one prompt: the dictation on stdin
# (may be empty), a blank line, then the selected text (built by selection-prompt.sh).
# HERDR_BIN names the herdr-app binary, HERDR_CLAUDE_CWD the new tab's directory.
set -u
herdr=${HERDR_BIN:-herdr-app}
prompt=$("$(dirname "$0")/selection-prompt.sh") || exit $?

# Why: keypipe's onFail.output would get only the dictation, so the whole prompt is saved here.
# The clipboard words come first: the notification keeps only the start of a long reason.
fail() {
  printf '%s' "$prompt" | pbcopy
  echo "herdr-claude: prompt copied to the clipboard; $1" >&2
  exit 1
}

# Why: herdr-app reads a --task value that parses as JSON (42, [1], null) as JSON and drops it,
# and passes the task to claude as an argument, where a leading "-" is an option. One JSON object
# keeps the task a string, and "--" ends claude's options. The x guards osascript's own options.
# Without a folder the tab opens in the focused terminal's folder, one Claude Code already trusts.
json=$(/usr/bin/osascript -l JavaScript -e 'function run(a) {
  var o = { name: "claude", argv: ["claude", "--"], task: a[0].slice(1) };
  if (a[1].length > 1) o.folder = a[1].slice(1);
  return JSON.stringify(o);
}' "x$prompt" "x${HERDR_CLAUDE_CWD:-}") || fail "could not encode the prompt"
cmd=tab.new
out=$("$herdr" do $cmd "$json" 2>&1) && exit 0
# Why: tab.new needs an open space; with every space closed, space.new opens one that starts
# the same agent with the same task.
case $out in
  *"no space yet"*) cmd=space.new; out=$("$herdr" do $cmd "$json" 2>&1) && exit 0 ;;
esac
fail "$cmd failed: $(printf '%s' "$out" | tr -s '\n\t ' ' ')"
