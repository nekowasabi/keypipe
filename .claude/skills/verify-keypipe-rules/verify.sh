#!/usr/bin/env bash
# Verifies the context-rule pipeline in docs/design/context-rules.md.
# Usage: verify.sh [--doctor] [--no-live]
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
EV="${KP_EVIDENCE:-$REPO/.verify-evidence/rules-$RUN_ID}"
BIN="$REPO/.build/debug/keypipe"
mkdir -p "$EV"
printf 'item\tstatus\tdetail\n' > "$EV/results.tsv"

PASS=0; FAIL=0; SKIP=0
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$EV/results.tsv"; }
ok() { PASS=$((PASS + 1)); echo "PASS $1"; row "$1" PASS "${2:-}"; }
ng() { FAIL=$((FAIL + 1)); echo "FAIL $1 :: $2"; row "$1" FAIL "$2"; }
sk() { SKIP=$((SKIP + 1)); echo "SKIP $1 :: $2"; row "$1" SKIP "$2"; }
check() { if eval "$2"; then ok "$1" "$3"; else ng "$1" "$3"; fi; }
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }

STARTED_PIDS=""
TMUX_SOCK="kpv-$$"
cleanup() {
  for p in $STARTED_PIDS; do kill -TERM "$p" 2>/dev/null; done
  if command -v tmux >/dev/null 2>&1; then tmux -L "$TMUX_SOCK" kill-server 2>/dev/null; fi
  [ -f "$EV/results.tsv" ] || echo "FAIL cleanup removed evidence"
}
trap cleanup EXIT

# feed <name> <config-json> <context-json> <keys>
feed() {
  printf '%s' "$2" > "$EV/$1.config.json"
  printf '%s' "$3" > "$EV/$1.context.json"
  cap 20 "$BIN" --config "$EV/$1.config.json" --context "$EV/$1.context.json" \
    --smoke-feed "$4" > "$EV/$1.out" 2>&1
  echo $? > "$EV/$1.exit"
}
has() { grep -qF -- "$2" "$EV/$1.out"; }
lacks() { ! grep -qF -- "$2" "$EV/$1.out"; }
exitis() { [ "$(cat "$EV/$1.exit")" = "$2" ]; }
field() { has "$1" "keypipe field $2"; }

{
  echo "repo=$REPO"
  echo "commit=$(git -C "$REPO" rev-parse --short HEAD 2>&1)"
  echo "uname=$(uname -a)"
  swift --version 2>&1 | head -n 1
  command -v tmux >/dev/null 2>&1 && tmux -V
} > "$EV/env.txt" 2>&1
cat "$EV/env.txt"

# R0 doctor
[ "$(uname -s)" = Darwin ] && ok "R0a macOS host" || ng "R0a macOS host" "uname is $(uname -s); live items need macOS"
command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1 \
  && ok "R0b swift toolchain" || ng "R0b swift toolchain" "swift missing or broken"
if [ "${1:-}" = "--doctor" ]; then
  [ -x "$BIN" ] && cap 10 "$BIN" --probe > "$EV/probe.json" 2>&1 && cat "$EV/probe.json"
  echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"
  [ "$FAIL" -eq 0 ]; exit
fi

# R1 build and tests
cd "$REPO" || exit 1
check "R1a swift build" "swift build > '$EV/build.log' 2>&1" "build.log"
check "R1b swift test" "swift test > '$EV/test.log' 2>&1" "test.log"
if command -v swift-format >/dev/null 2>&1; then
  check "R1c swift-format lint" "swift-format lint --strict --recursive Sources Tests > '$EV/lint.log' 2>&1" "lint.log"
else
  sk "R1c swift-format lint" "swift-format not on PATH"
fi
if [ ! -x "$BIN" ]; then
  ng "R2-R7" "binary missing at $BIN, feed items not run"
  echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"; exit 1
fi

TXT='{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello"}'

# R2 config boundary. bad <id> <config> <reason>: exit 1 and the line
# "invalid config: <reason>". A generic rejection (e.g. the old loader
# refusing a config for a missing key) must not pass.
bad() {
  printf '%s' "$2" > "$EV/$1.config.json"
  cap 10 "$BIN" --config "$EV/$1.config.json" --smoke-feed '@@@' > "$EV/$1.out" 2>&1
  local code=$?
  echo "$code" > "$EV/$1.exit"
  if [ "$code" = 1 ] && has "$1" "invalid config: $3"; then ok "$1" "$3"; else ng "$1" "$3 (exit $code)"; fi
}
bad R2a '{"rules":[{"trigger":""}]}' "empty trigger"
bad R2b '{"rules":[{"trigger":"@@@","action":{"type":"shell","command":"echo x"}}]}' "unknown key action"
bad R2c '{"rules":[{"trigger":"@@@","output":"replaceAll"}]}' "unknown output replaceAll"
bad R2d '{"rules":[{"trigger":"@@@","output":{"shell":""}}]}' "empty output.shell"
bad R2e '{"rules":[{"trigger":"@@@","transform":""}]}' "empty transform"
bad R2f '{"rules":[{"trigger":"@@@","when":{"focus":"window"}}]}' "unknown focus window"
feed R2g '{"rules":[{"trigger":"@@@"}]}' "$TXT" '@@@'
check "R2g minimal rule accepted" "exitis R2g 0 && has R2g 'keypipe matched @@@ rule 0'" "defaults: when any, identity, output none"

# R3 rule selection by context
SEL='{"rules":[
 {"trigger":"@@@","when":{"app":["com.apple.Terminal"]},"output":"none"},
 {"trigger":"@@@","when":{"focus":"textField"},"output":"none"}]}'
feed R3a "$SEL" "$TXT" '@@@'
check "R3a text field picks rule 1" "has R3a 'keypipe matched @@@ rule 1'" ""
feed R3b "$SEL" '{"app":"com.apple.Terminal","focusIsTextField":false,"fieldText":""}' '@@@'
check "R3b app filter picks rule 0" "has R3b 'keypipe matched @@@ rule 0'" ""
feed R3c "$SEL" '{"app":"com.apple.finder","focusIsTextField":false,"fieldText":""}' '@@@'
check "R3c no rule satisfied: no fire, no erase" "exitis R3c 2 && has R3c 'keypipe nomatch @@@' && lacks R3c 'keypipe erase '" ""
SEL2='{"rules":[
 {"trigger":"@@@","when":{"focus":"textField"},"output":"none"},
 {"trigger":"@@@","when":{"focus":"textField"},"output":"none"}]}'
feed R3d "$SEL2" "$TXT" '@@@'
check "R3d first satisfied rule in config order wins" "has R3d 'keypipe matched @@@ rule 0'" ""
feed R3e "{\"rules\":[{\"trigger\":\"@@@\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/R3e.sent'\"}}]}" "$TXT" '@@@'
check "R3e focus any in a text field: trigger erased, input empty, field untouched" \
  "has R3e 'keypipe erase 3' && [ -f '$EV/R3e.sent' ] && [ ! -s '$EV/R3e.sent' ] && field R3e '\"hello\"'" "R3e.sent empty"

# R4 erase then read the field
UP='{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"tr a-z A-Z","output":"replaceInput"}]}'
feed R4 "$UP" "$TXT" '@@@'
check "R4a trigger erased" "has R4 'keypipe erase 3'" ""
check "R4b field replaced without trigger chars" "field R4 '\"HELLO\"'" "field HELLO, not HELLO@@@"
feed R4c "$UP" '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello","backspacePerRead":true}' '@@@'
check "R4c Backspaces delivered one per read: wait for all, no rewrite" \
  "lacks R4c 'keypipe erase-rewrite' && field R4c '\"HELLO\"'" "field HELLO, not HE or HELLO@@"
feed R4d "$UP" '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello","ignoresBackspace":true}' '@@@'
check "R4d app ignores Backspace: trigger removed by AXValue rewrite" \
  "has R4d 'keypipe erase-rewrite' && field R4d '\"HELLO\"'" "field HELLO"
feed R4e "$UP" '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello","keysPerRead":true}' '@@@'
check "R4e trigger keys land after the tap sees them: wait before erasing" \
  "lacks R4e 'keypipe erase-rewrite' && field R4e '\"HELLO\"'" "field HELLO, not HE@@ or HELL@@"

# R5 transform contract
CH='{"rules":[{"when":{"focus":"textField"},"trigger":"@@@","transform":"printf \"stdin=%s arg=%s env=%s app=%s\" \"$(cat)\" \"$1\" \"$KEYPIPE_INPUT\" \"$KEYPIPE_APP\"","output":"replaceInput"}]}'
feed R5a "$CH" "$TXT" '@@@'
check "R5a input on stdin, \$1, KEYPIPE_INPUT; app in KEYPIPE_APP" \
  "field R5a '\"stdin=hello arg=hello env=hello app=com.apple.TextEdit\"'" ""
feed R5b '{"rules":[{"when":{"focus":"textField"},"trigger":"@@@","transform":"echo HELLO","output":"replaceInput"}]}' "$TXT" '@@@'
check "R5b one trailing newline stripped" "field R5b '\"HELLO\"'" ""
feed R5c '{"rules":[{"when":{"focus":"textField"},"trigger":"@@@","transform":"exit 3","output":"replaceInput"}]}' "$TXT" '@@@'
check "R5c failing transform: no output, notify, field keeps text" \
  "has R5c 'keypipe transform exit 3' && lacks R5c 'keypipe apply replaceInput' && has R5c 'keypipe apply notify' && field R5c '\"hello\"'" ""
feed R5d '{"rules":[{"when":{"focus":"textField"},"trigger":"@@@","transform":"true","output":"replaceInput"}]}' "$TXT" '@@@'
check "R5d empty transform output: notify, field not wiped" \
  "has R5d 'keypipe transform empty' && lacks R5d 'keypipe apply replaceInput' && has R5d 'keypipe apply notify' && field R5d '\"hello\"'" ""

# R6 shell output (tmux, Herdr, Grok Bot, CotEditor stand in here)
feed R6a "{\"rules\":[{\"when\":{\"focus\":\"textField\"},\"trigger\":\"@@@\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/R6a.sent'\"}}]}" "$TXT" '@@@'
check "R6a identity input reaches output.shell as \$1" "[ \"\$(cat '$EV/R6a.sent' 2>/dev/null)\" = hello ]" "R6a.sent"
feed R6b "{\"rules\":[{\"when\":{\"focus\":\"textField\"},\"trigger\":\"@@@\",\"transform\":\"tr a-z A-Z\",\"output\":{\"shell\":\"cat > '$EV/R6b.sent'\"}}]}" "$TXT" '@@@'
check "R6b transform result reaches output.shell on stdin" "[ \"\$(cat '$EV/R6b.sent' 2>/dev/null)\" = HELLO ]" "R6b.sent"
if command -v tmux >/dev/null 2>&1; then
  tmux -L "$TMUX_SOCK" new-session -d -s kpv -x 120 -y 10
  feed R6c "{\"rules\":[{\"when\":{\"focus\":\"textField\"},\"trigger\":\";;;\",\"output\":{\"shell\":\"tmux -L $TMUX_SOCK send-keys -t kpv -l \\\"\$1\\\"\"}}]}" "$TXT" ';;;'
  tmux -L "$TMUX_SOCK" capture-pane -p -t kpv > "$EV/R6c.pane" 2>&1
  check "R6c text sent to a real tmux pane" "grep -qF hello '$EV/R6c.pane'" "R6c.pane"
else
  sk "R6c text sent to a real tmux pane" "tmux not on PATH"
fi

# R7 multibyte passes through intact
feed R7 "{\"rules\":[{\"when\":{\"focus\":\"textField\"},\"trigger\":\"@@@\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/R7.sent'\"}}]}" \
  '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"こんにちは 世界"}' '@@@'
check "R7 Japanese field text intact" "[ \"\$(cat '$EV/R7.sent' 2>/dev/null)\" = 'こんにちは 世界' ]" "R7.sent"

# R8 shell injection: field text is data, never code, through transform and output.shell
INJ_TXT='$(touch '"$EV"'/R8.pwned) `touch '"$EV"'/R8.pwned2` "dq" '"'"'sq'"'"' ; echo x'
printf '%s' "$INJ_TXT" > "$EV/R8.expected"
INJ_JSON="$(printf '%s' "$INJ_TXT" | sed 's/"/\\"/g')"
feed R8 "{\"rules\":[{\"when\":{\"focus\":\"textField\"},\"trigger\":\"@@@\",\"transform\":\"cat\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/R8.sent'\"}}]}" \
  "{\"app\":\"com.apple.TextEdit\",\"focusIsTextField\":true,\"fieldText\":\"$INJ_JSON\"}" '@@@'
check "R8 field text with \$(), backticks, quotes is not executed and arrives byte-exact" \
  "[ ! -e '$EV/R8.pwned' ] && [ ! -e '$EV/R8.pwned2' ] && cmp -s '$EV/R8.sent' '$EV/R8.expected'" "R8.sent vs R8.expected"

# M live macOS items: real CGEventTap and AX, driven through System Events
if [ "${1:-}" = "--no-live" ] || [ "$(uname -s)" != Darwin ]; then
  sk "M1-M4 live macOS" "not Darwin or --no-live"
else
  cap 10 "$BIN" --probe > "$EV/M0.probe.json" 2>&1
  if grep -q '"trusted":true' "$EV/M0.probe.json"; then ok "M0 Accessibility granted to keypipe" "M0.probe.json"
  else ng "M0 Accessibility granted to keypipe" "grant it in System Settings > Privacy > Accessibility, see M0.probe.json"; fi

  LIVE="{\"rules\":[
   {\"trigger\":\"@@@\",\"when\":{\"focus\":\"textField\"},\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"},
   {\"trigger\":\";;;\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/M2.sent'\"}}]}"
  printf '%s' "$LIVE" > "$EV/live.config.json"
  "$BIN" --config "$EV/live.config.json" > "$EV/daemon.log" 2>&1 &
  DPID=$!; STARTED_PIDS="$STARTED_PIDS $DPID"; echo "$DPID" > "$EV/daemon.pid"
  STARTED=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'keypipe started' "$EV/daemon.log" && STARTED=1 && break; sleep 0.5; done
  if [ "$STARTED" = 1 ]; then ok "M0b daemon started" "daemon.log"
  else ng "M0b daemon started" "no 'keypipe started' within 5s, see daemon.log; M1-M4 not run"; fi
fi
if [ "${1:-}" != "--no-live" ] && [ "$(uname -s)" = Darwin ] && [ "${STARTED:-0}" = 1 ]; then
  osa() { osascript -e "$1" 2>&1; }
  osa 'tell application "TextEdit" to activate' >/dev/null
  # Only the document this run created is ever read, cleared, or closed.
  DOC="$(osascript -e 'tell application "TextEdit" to get name of (make new document)' 2>"$EV/M1.osa.err")"
  sleep 1
  front_is_ours() { [ -n "$DOC" ] && [ "$(osa 'tell application "TextEdit" to get name of front document')" = "$DOC" ]; }
  if ! front_is_ours; then
    ng "M1-M2 TextEdit" "could not create or front our own document (DOC='$DOC'), see M1.osa.err; M1-M2 not run"
  else
    echo "$DOC" > "$EV/M1.document"
    osa 'tell application "System Events" to keystroke "hello@@@"' >/dev/null
    sleep 2
    osa "tell application \"TextEdit\" to get text of document \"$DOC\"" > "$EV/M1.text"
    check "M1 TextEdit: hello@@@ becomes HELLO" "[ \"\$(cat '$EV/M1.text')\" = HELLO ]" "M1.text, daemon.log"

    osa "tell application \"TextEdit\" to set text of document \"$DOC\" to \"\"" >/dev/null
    if front_is_ours; then
      # Digit first: TextEdit auto-capitalizes a sentence-initial letter (abc;;; became Abc).
      osa 'tell application "System Events" to keystroke "1abc;;;"' >/dev/null
      sleep 2
      osa "tell application \"TextEdit\" to get text of document \"$DOC\"" > "$EV/M2.text"
      check "M2 TextEdit: 1abc;;; sends 1abc to output.shell and erases trigger" \
        "[ \"\$(cat '$EV/M2.sent' 2>/dev/null)\" = 1abc ] && [ \"\$(cat '$EV/M2.text')\" = 1abc ]" "M2.sent, M2.text"
    else
      ng "M2 TextEdit" "our document lost focus before typing; not typed"
    fi
    osa "tell application \"TextEdit\" to close document \"$DOC\" saving no" >/dev/null
  fi

  osa 'tell application "Finder" to activate' >/dev/null
  sleep 1
  # Positive control: the daemon must see the trigger (nomatch +1) and stay
  # alive; an unchanged matched count alone would also pass for a dead daemon.
  before_m=$(grep -c 'keypipe matched' "$EV/daemon.log")
  before_n=$(grep -c 'keypipe nomatch' "$EV/daemon.log")
  osa 'tell application "System Events" to keystroke "@@@"' >/dev/null
  sleep 1
  after_m=$(grep -c 'keypipe matched' "$EV/daemon.log")
  after_n=$(grep -c 'keypipe nomatch' "$EV/daemon.log")
  check "M3 Finder (no text field): @@@ seen, no rule fires, daemon alive" \
    "[ '$before_m' = '$after_m' ] && [ '$after_n' = '$((before_n + 1))' ] && kill -0 '$DPID' 2>/dev/null" \
    "matched $before_m->$after_m nomatch $before_n->$after_n, daemon.log"

  if [ -d /Applications/iTerm.app ]; then
    osa 'tell application "iTerm" to activate' >/dev/null
    sleep 1
    cap 10 "$BIN" --probe > "$EV/M4.probe.json" 2>&1
    check "M4 iTerm2 probe recorded (risk: prompt may not be a text field)" "grep -q focusIsTextField '$EV/M4.probe.json'" "$(cat "$EV/M4.probe.json")"
  else
    sk "M4 iTerm2 probe" "/Applications/iTerm.app absent"
  fi
fi

echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"
[ "$FAIL" -eq 0 ]
