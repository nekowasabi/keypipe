#!/bin/bash
# Checks shell/herdr-claude.sh and the keypipe rule that calls it, against stubs of herdr,
# the clipboard, osascript (the synthetic Cmd+C copies STUB_SELECTION) and open.
# LIVE=1 also sends one prompt through the real Herdr and closes the tab it opened.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
script=$root/shell/herdr-claude.sh
keypipe=$root/.build/debug/keypipe
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

mkdir -p "$work/bin"
cat >"$work/bin/herdr" <<'EOF'
#!/bin/sh
echo "$1 $2" >>"$STUB_CALLS"
case "$1 $2" in
  "tab create") [ -z "${STUB_FAIL:-}" ] || exit 1
    echo '{"result":{"root_pane":{"pane_id":"w9:pZ","cwd":"/x"}}}' ;;
  "agent prompt") [ "$3" = w9:pZ ] || exit 1; printf '%s' "$4" >"$STUB_PROMPT" ;;
esac
EOF
printf '#!/bin/sh\ncat "$STUB_CLIP"\n' >"$work/bin/pbpaste"
printf '#!/bin/sh\ncat >"$STUB_CLIP"\n' >"$work/bin/pbcopy"
printf '#!/bin/sh\ncp "$STUB_SELECTION" "$STUB_CLIP"\n' >"$work/bin/osascript"
printf '#!/bin/sh\necho "open $*" >>"$STUB_CALLS"\n' >"$work/bin/open"
chmod +x "$work/bin/"*
export STUB_CALLS=$work/calls STUB_PROMPT=$work/prompt STUB_CLIP=$work/clip
export STUB_SELECTION=$work/selection
reset() {
  rm -f "$STUB_CALLS" "$STUB_PROMPT"
  printf '%s' "$1" >"$STUB_SELECTION"
  printf 'OLD' >"$STUB_CLIP"
}
calls() { tr '\n' ',' <"$STUB_CALLS" 2>/dev/null; }
clip_is() { printf '%s' "$1" >"$work/want"; cmp -s "$work/want" "$STUB_CLIP"; }
# Passes when the TEXT agent prompt received equals $1 byte for byte.
prompt_is() { printf '%s' "$1" >"$work/want"; cmp -s "$work/want" "$STUB_PROMPT"; }

# Runs the script with dictation $1 and selection $2.
run() {
  reset "$2"
  printf '%s' "$1" | PATH=$work/bin:/usr/bin:/bin HERDR_BIN=$work/bin/herdr "$script" 2>"$work/err"
  code=$?
}

tricky=$(printf "line1 'q' \"dq\" \$HOME \`x\` \$(echo hi)\nline2 日本語\n%02000d" 0)
run "" "$tricky"
if [ "$code" = 0 ] && prompt_is "$tricky" && ! grep -q 'pane run' "$STUB_CALLS"; then
  pass "V3 the selection reaches agent prompt as one argument, byte for byte, with no pane run"
else fail V3 "exit $code, calls: $(calls) $(cat "$work/err")"; fi
if clip_is OLD; then pass "V3 the clipboard is restored after the copy"
else fail V3 "clipboard left as: $(cat "$STUB_CLIP")"; fi

run "" ""
if [ "$code" = 3 ] && [ ! -e "$STUB_CALLS" ] && clip_is OLD; then
  pass "V4 nothing selected or said opens no tab, fails, and leaves the clipboard alone"
else fail V4 "exit $code, calls: $(calls)"; fi

STUB_FAIL=1 run "要約して" "body"
if [ "$code" = 1 ] && clip_is "$(printf '要約して\n\nbody')"; then
  pass "V5 a failing tab create leaves the whole prompt on the clipboard"
else fail V5 "exit $code, clipboard: $(cat "$STUB_CLIP")"; fi

run "要約して" "body"
if [ "$code" = 0 ] && prompt_is "$(printf '要約して\n\nbody')"; then pass "V9 dictation, a blank line, then the selection"
else fail V9 "exit $code, prompt: $(cat "$STUB_PROMPT" 2>/dev/null)"; fi

run "要約して" ""
if [ "$code" = 0 ] && prompt_is "要約して"; then pass "V10 the dictation alone when nothing is selected"
else fail V10 "exit $code, prompt: $(cat "$STUB_PROMPT" 2>/dev/null)"; fi

reset body
printf '要約して' | VOICE_SWITCH_APP=com.apple.TextEdit PATH=$work/bin:/usr/bin:/bin \
  HERDR_BIN=$work/bin/herdr "$script" 2>/dev/null
if [ "$(head -1 "$STUB_CALLS")" = "open -b com.apple.TextEdit" ]; then
  pass "V11 VOICE_SWITCH_APP is brought forward before the copy"
else fail V11 "calls: $(calls)"; fi

cfg=$work/config.json
cat >"$cfg" <<EOF
{ "rules": [ { "name": "herdr-claude", "hotkey": "ctrl+alt+cmd+j", "when": { "focus": "any" },
  "output": { "shell": "PATH=$work/bin:/usr/bin:/bin HERDR_BIN=$work/bin/herdr $script", "background": true } } ] }
EOF
if "$keypipe" --config "$cfg" --triggers >/dev/null 2>&1; then pass "V1 the rule's config loads"
else fail V1 "config rejected"; fi

reset body
report=$(printf '要約して' | env -i HOME="$HOME" STUB_CALLS="$STUB_CALLS" STUB_PROMPT="$STUB_PROMPT" \
  STUB_CLIP="$STUB_CLIP" STUB_SELECTION="$STUB_SELECTION" XDG_STATE_HOME="$work/state" \
  "$keypipe" --config "$cfg" --rule herdr-claude --report 2>/dev/null)
for _ in $(seq 50); do [ -e "$STUB_PROMPT" ] && break; sleep 0.2; done
case $report in
  *'"started"'*) if prompt_is "$(printf '要約して\n\nbody')"; then
      pass "V2/V6 --rule starts a background job that sends dictation plus selection, with no login PATH"
    else fail V6 "calls: $(calls); jobs.log: $(cat "$work/state/keypipe/jobs.log" 2>/dev/null)"; fi ;;
  *) fail V2 "report: $report" ;;
esac

if grep -q '/Users/' "$script"; then fail V6 "a user path is written into the repo"
else pass "V6 no user path in the repo files"; fi

if [ -n "${LIVE:-}" ]; then
  tabs() { herdr tab list | grep -o '"tab_id":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/' | sort; }
  real=$(command -v herdr)
  before=$(tabs)
  reset ""
  printf 'OK とだけ返して' | PATH=$work/bin:$PATH HERDR_BIN=$real HERDR_CLAUDE_CWD=$root "$script"
  code=$?
  new=$(comm -13 <(echo "$before") <(tabs))
  if [ "$code" = 0 ] && [ "$(echo "$new" | grep -c .)" = 1 ]; then
    pass "V2/V7 live: one new Herdr tab with Claude Code in $root"
  else fail V2 "live exit $code, new tabs: $new"; fi
  for t in $new; do herdr tab close "$t" >/dev/null; done
fi

[ "$fails" = 0 ] && echo "ALL PASS" || echo "$fails FAIL"
exit $((fails > 0))
