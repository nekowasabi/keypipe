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
bad R2h '{"rules":[{"output":"none"}]}' "rule needs trigger or hotkey"
# An unknown argument must stop with the usage, not start the daemon (cap kills a daemon, so exit is not 2).
cap 10 "$BIN" --config "$EV/R2g.config.json" --hepl > "$EV/R2u.out" 2>&1; echo $? > "$EV/R2u.exit"
check "R2u unknown argument: usage, exit 2, no daemon" "exitis R2u 2 && has R2u 'keypipe: unknown argument --hepl' && has R2u 'usage: keypipe'" ""
bad R2i '{"rules":[{"trigger":"@@@","hotkey":"ctrl+@"}]}' "rule has both trigger and hotkey"
bad R2j '{"rules":[{"hotkey":"@"}]}' "hotkey needs a modifier"
bad R2k '{"rules":[{"hotkey":"meta+@"}]}' "unknown modifier meta"
bad R2l '{"rules":[{"hotkey":"ctrl+shift+a"}]}' "shift is written in the key (ctrl+A)"

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
feed R4f "$UP" '{"app":"com.google.Chrome","focusIsTextField":true,"fieldText":"hello","writePerRead":true}' '@@@'
check "R4f AXValue write lands one read later (Chromium): written, not ignored" \
  "has R4f 'keypipe apply replaceInput \"HELLO\"' && lacks R4f 'keypipe apply-failed' && field R4f '\"HELLO\"'" "field HELLO"
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

# R9 fallbacks: onFail per stage, shellTimeout, KEYPIPE_FAILURE
FB='"when":{"focus":"textField"},"trigger":"@@@"'
feed R9a "{\"shellTimeout\":1,\"rules\":[{$FB,\"transform\":\"sleep 5\",\"output\":\"replaceInput\",\"onFail\":{\"transform\":\"tr a-z A-Z\"}}]}" "$TXT" '@@@'
check "R9a transform timeout falls back to onFail.transform" \
  "exitis R9a 0 && has R9a 'keypipe transform timeout 1' && has R9a 'keypipe fallback transform exit 0' && field R9a '\"HELLO\"'" "field HELLO within cap 20"
feed R9b "{\"rules\":[{$FB,\"transform\":\"exit 3\",\"output\":\"replaceInput\",\"onFail\":{\"transform\":\"exit 4\"}}]}" "$TXT" '@@@'
check "R9b fallback failure notifies once, field kept" \
  "has R9b 'keypipe fallback transform exit 4' && has R9b 'keypipe apply notify \"@@@ transform failed: exit 4\"' && lacks R9b 'keypipe apply replaceInput' && field R9b '\"hello\"'" ""
feed R9c "{\"rules\":[{$FB,\"transform\":\"true\",\"output\":\"replaceInput\"}]}" "$TXT" '@@@'
check "R9c empty output without onFail notifies, field kept" \
  "has R9c 'keypipe transform empty' && has R9c 'keypipe apply notify' && field R9c '\"hello\"'" ""
feed R9d "{\"rules\":[{$FB,\"output\":{\"shell\":\"exit 1\"},\"onFail\":{\"output\":{\"shell\":\"printf '%s|%s' \\\"\$1\\\" \\\"\$KEYPIPE_FAILURE\\\" > '$EV/R9d.sent'\"}}}]}" "$TXT" '@@@'
check "R9d output.shell failure runs onFail.output with \$1 and KEYPIPE_FAILURE" \
  "has R9d 'keypipe output-shell exit 1' && has R9d 'keypipe fallback output-shell exit 0' && [ \"\$(cat '$EV/R9d.sent' 2>/dev/null)\" = 'hello|exit 1' ]" "R9d.sent"
feed R9e "{\"rules\":[{$FB,\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\",\"onFail\":{\"output\":{\"shell\":\"printf '%s|%s' \\\"\$1\\\" \\\"\$KEYPIPE_FAILURE\\\" > '$EV/R9e.sent'\"}}}]}" \
  '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello","ignoresWrite":true}' '@@@'
check "R9e ignored AXValue write falls back to onFail.output with the result" \
  "has R9e 'keypipe apply-failed replaceInput ignored' && lacks R9e 'keypipe apply replaceInput' && [ \"\$(cat '$EV/R9e.sent' 2>/dev/null)\" = 'HELLO|ignored' ]" "R9e.sent"
feed R9f "{\"rules\":[{$FB,\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"}]}" \
  '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello","fieldGoneAfter":"erase"}' '@@@'
check "R9f field gone after erase: no write elsewhere, result notified" \
  "has R9f 'keypipe apply-failed replaceInput gone' && has R9f 'keypipe apply notify \"HELLO\"'" ""
feed R9g "{\"shellTimeout\":1,\"rules\":[{$FB,\"transform\":\"sleep 5\",\"output\":\"replaceInput\",\"onFail\":{\"transform\":\"sleep 5\"}}]}" "$TXT" '@@@'
check "R9g fallback also times out: two shells, then notify" \
  "has R9g 'keypipe fallback transform timeout 1' && has R9g 'keypipe apply notify \"@@@ transform failed: timeout\"' && field R9g '\"hello\"'" "finishes inside cap 20"
bad R9h "{\"rules\":[{$FB,\"onFail\":{\"transform\":\"x\"}}]}" "onFail.transform requires transform"
bad R9i "{\"rules\":[{$FB,\"output\":\"notify\",\"onFail\":{\"output\":\"none\"}}]}" "onFail.output requires an output that can fail"
bad R9j "{\"rules\":[{$FB,\"onFail\":{\"erase\":\"x\"}}]}" "unknown key erase"
bad R9k '{"shellTimeout":0,"rules":[]}' "shellTimeout must be positive"
feed R9l '{"rules":[{"trigger":"@@@","when":{"app":["com.example.other"]}},{"trigger":"@@@"}]}' "$TXT" '@@@'
check "R9l catch-all rule (same trigger, no when) fires when the first rule does not hold" \
  "has R9l 'keypipe matched @@@ rule 1' && lacks R9l 'keypipe nomatch'" ""

# R10 hotkeys: no erase, field is the input, unconfigured chords are silent
HK='{"rules":[{"hotkey":"ctrl+@","when":{"focus":"textField"},"transform":"tr a-z A-Z","output":"replaceInput"}]}'
printf '%s' "$HK" > "$EV/R10a.config.json"; printf '%s' "$TXT" > "$EV/R10a.context.json"
cap 20 "$BIN" --config "$EV/R10a.config.json" --context "$EV/R10a.context.json" --smoke-hotkey 'control+@' > "$EV/R10a.out" 2>&1
echo $? > "$EV/R10a.exit"
check "R10a hotkey in a text field: field is the input, nothing erased, result written" \
  "exitis R10a 0 && has R10a 'keypipe matched ctrl+@ rule 0' && has R10a 'keypipe erase 0' && lacks R10a 'keypipe erase-rewrite' && field R10a '\"HELLO\"'" "field HELLO, erase 0"
HKANY="{\"rules\":[{\"hotkey\":\"ctrl+@\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/R10b.sent'\"}}]}"
printf '%s' "$HKANY" > "$EV/R10b.config.json"; printf '%s' "$TXT" > "$EV/R10b.context.json"
cap 20 "$BIN" --config "$EV/R10b.config.json" --context "$EV/R10b.context.json" --smoke-feed 'ab' --smoke-hotkey 'ctrl+@' > "$EV/R10b.out" 2>&1
echo $? > "$EV/R10b.exit"
check "R10b hotkey under focus any: empty input, field untouched" \
  "exitis R10b 0 && has R10b 'keypipe erase 0' && [ -f '$EV/R10b.sent' ] && [ ! -s '$EV/R10b.sent' ] && field R10b '\"helloab\"'" "R10b.sent empty, field helloab"
printf '%s' "$HK" > "$EV/R10c.config.json"; printf '%s' "$TXT" > "$EV/R10c.context.json"
cap 20 "$BIN" --config "$EV/R10c.config.json" --context "$EV/R10c.context.json" --smoke-feed '@@' --smoke-hotkey 'cmd+c' > "$EV/R10c.out" 2>&1
echo $? > "$EV/R10c.exit"
check "R10c unconfigured chord: no transcript line, no nomatch, exit 2" \
  "exitis R10c 2 && lacks R10c 'keypipe nomatch' && lacks R10c 'keypipe matched'" "cmd+c is silent"

# R11 --line --report (PR1 of docs/design/extension-architecture.md)
# line <name> <config-json> <trigger> <stdin> [extra args...]: stdout to .out, stderr to .err
line() {
  local name=$1 cfg=$2 trig=$3 input=$4; shift 4
  printf '%s' "$cfg" > "$EV/$name.config.json"
  printf '%s' "$input" | cap 20 "$BIN" --config "$EV/$name.config.json" --line "$trig" "$@" > "$EV/$name.out" 2> "$EV/$name.err"
  echo $? > "$EV/$name.exit"
}
same() { [ "$(cat "$EV/$1.out")" = "$2" ]; }
LR='{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"tr a-z A-Z","output":"replaceInput"},{"trigger":";;;","when":{"focus":"textField"},"transform":"exit 3"},{"trigger":"///","when":{"focus":"textField"},"output":{"shell":"cat > /dev/null"}}]}'
line R11a1 "$LR" '@@@' 'hello' --report
line R11a2 "$LR" ';;;' 'hello' --report
line R11a3 "$LR" '///' 'hello' --report
line R11a4 "$LR" 'zz' 'hello' --report
line R11a5 "$LR" ';;;' 'hello'
line R11a6 "$LR" 'zz' 'hello'
check "R11a --report: one JSON line per outcome, exit 0; plain --line unchanged" \
  "exitis R11a1 0 && same R11a1 '{\"outcome\":\"replaced\",\"rule\":0,\"text\":\"HELLO\",\"v\":1}' \
   && same R11a2 '{\"failure\":\"exit 3\",\"outcome\":\"failed\",\"rule\":1,\"stage\":\"transform\",\"v\":1}' \
   && same R11a3 '{\"outcome\":\"delivered\",\"rule\":2,\"v\":1}' \
   && exitis R11a4 0 && same R11a4 '{\"outcome\":\"nomatch\",\"v\":1}' \
   && exitis R11a5 0 && same R11a5 'hello' && exitis R11a6 2 && same R11a6 ''" \
  "R11a*.out: failed transform is still a hit for plain --line (exit 0, line unchanged)"
# R11b: a background output reports started only with a job that did spawn. The failing spawn
# is covered in-process (EngineTests.testFailedSpawnIsReportedAsFailedNotStarted): breaking
# posix_spawn from outside the binary is not reliable.
line R11b '{"rules":[{"trigger":"&&&","when":{"focus":"textField"},"output":{"shell":"true","background":true}}]}' '&&&' 'note' --report
check "R11b background spawn reports started, and never next to background-failed spawn" \
  "same R11b '{\"outcome\":\"started\",\"rule\":0,\"v\":1}' && ! grep -qF 'background-failed spawn' '$EV/R11b.err'" \
  "R11b.out/.err"

# R12 condition facts, deny and gates (PR2). Facts come from the context's "facts" by name.
URLR='{"rules":[{"trigger":"@@@","when":{"app":["com.google.Chrome"],"focus":"textField","url":["https://github.com/*"]},"transform":"tr a-z A-Z","output":"replaceInput"},{"trigger":"@@@","when":{"focus":"textField"},"transform":"tr a-z A-Y","output":"replaceInput"}]}'
CHROME='{"app":"com.google.Chrome","focusIsTextField":true,"fieldText":"hiz"'
feed R12a1 "$URLR" "$CHROME"',"facts":{"url":"https://github.com/a/b"}}' '@@@'
feed R12a2 "$URLR" "$CHROME"',"facts":{"url":"https://example.com/"}}' '@@@'
check "R12a url rule fires only on its site; elsewhere the next rule does" \
  "has R12a1 'keypipe matched @@@ rule 0' && field R12a1 '\"HIZ\"' && has R12a2 'keypipe matched @@@ rule 1' && field R12a2 '\"HIY\"'" "R12a*.out"
feed R12b1 "$URLR" "$CHROME"',"unreadableFacts":{"url":"timeout"}}' '@@@'
feed R12b2 "$URLR" '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hiz"}' '@@@'
check "R12b unreadable url stops the fire (no erase, no next rule); another app never reads it" \
  "has R12b1 'keypipe unreadable @@@ url' && lacks R12b1 'keypipe matched' && field R12b1 '\"hiz@@@\"' \
   && exitis R12b1 2 && has R12b2 'keypipe matched @@@ rule 1'" "R12b*.out"
bad R12c1 '{"deny":[{"url":["*bank*"]}],"rules":[]}' 'deny url requires app'
DENY='{"deny":[{"app":["com.google.Chrome"],"url":["*bank.example*"]}],"rules":[{"trigger":"@@@"}]}'
feed R12c2 "$DENY" '{"app":"com.google.Chrome","focusIsTextField":false,"fieldText":"","facts":{"url":"https://bank.example/x"}}' '@@@'
feed R12c3 "$DENY" '{"app":"com.google.Chrome","focusIsTextField":false,"fieldText":"","unreadableFacts":{"url":"timeout"}}' '@@@'
feed R12c4 "$DENY" '{"app":"com.google.Chrome","focusIsTextField":false,"fieldText":"","facts":{"url":"https://github.com"}}' '@@@'
check "R12c deny with app+url blocks on match, stops with a reason when unreadable, passes elsewhere" \
  "has R12c2 'keypipe deny @@@' && has R12c3 'keypipe deny-unreadable @@@ url' && lacks R12c3 'keypipe matched' \
   && has R12c4 'keypipe matched @@@ rule 0'" "R12c*.out"
feed R12d '{"rules":[{"trigger":"@@@","output":{"shell":"echo ran > '"$EV"'/R12d.sent"}}]}' '{"app":"x","focusIsTextField":false,"fieldText":"","secure":true}' '@@@'
check "R12d password field: keypipe secure, nothing runs" \
  "has R12d 'keypipe secure @@@' && lacks R12d 'keypipe matched' && [ ! -e '$EV/R12d.sent' ]" "R12d.out"
TERMHK='{"rules":[{"hotkey":"ctrl+@","when":{"focus":"textField"},"output":{"shell":"echo no >> '"$EV"'/R12e.sent"}},{"hotkey":"ctrl+@","output":{"shell":"printf \"[%s]\" \"$1\" >> '"$EV"'/R12e.sent"}},{"trigger":"@@@","output":{"shell":"echo text >> '"$EV"'/R12e.sent"}}]}'
printf '%s' "$TERMHK" > "$EV/R12e.config.json"; printf '%s' '{"app":"com.example.term","ownsPty":true,"focusIsTextField":true,"fieldText":"pane-secret"}' > "$EV/R12e.context.json"
cap 20 "$BIN" --config "$EV/R12e.config.json" --context "$EV/R12e.context.json" --smoke-feed '@@@' --smoke-hotkey 'ctrl+@' > "$EV/R12e.out" 2>&1
check "R12e terminal: a focus-any hotkey runs with empty input; text triggers and textField rules stay blocked" \
  "has R12e 'keypipe terminal @@@' && has R12e 'keypipe matched ctrl+@ rule 1' && [ \"\$(cat '$EV/R12e.sent')\" = '[]' ]" "R12e.out R12e.sent"
feed R12f '{"rules":[{"trigger":"@@@","when":{"focus":"textField","url":["*"]},"output":{"shell":"true"}}]}' "$CHROME"',"facts":{"url":"https://x/"},"appAfterSlowRead":"com.apple.TextEdit"}' '@@@'
check "R12f app switched during the URL read: no erase, nothing runs" \
  "has R12f 'keypipe front-changed @@@' && lacks R12f 'keypipe matched' && field R12f '\"hiz@@@\"'" "R12f.out"
feed R12g '{"rules":[{"trigger":"@@@","when":{"app":["com.apple.*"]},"output":"none"}]}' "$TXT" '@@@'
check "R12g app globs: com.apple.* matches TextEdit" "has R12g 'keypipe matched @@@ rule 0'" "R12g.out"
feed R12h '{"rules":[{"trigger":"@@@","when":{"focus":"textField","url":["*"]},"transform":"tr a-z A-Z","output":"replaceInput"}]}' \
  '{"app":"com.google.Chrome","focusIsTextField":true,"fieldText":"hello","keysPerRead":true,"facts":{"url":"https://example.com/"}}' '@@@'
check "R12h a URL rule still waits for a late trigger key (R4e with a slow fact): fires, no front-changed" \
  "exitis R12h 0 && lacks R12h 'front-changed' && field R12h '\"HELLO\"'" "R12h.out"

# R13 native outputs from the sink table (PR3)
TT='{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"printf X","output":"typeText"},{"trigger":";;;","when":{"focus":"textField"},"transform":"printf Y","output":"typeText","onFail":{"output":{"shell":"printf \"%s|%s\" \"$1\" \"$KEYPIPE_FAILURE\" > '"$EV"'/R13a.sent"}}}]}'
feed R13a1 "$TT" "$TXT" '@@@'
line R13a2 "$TT" '@@@' 'hello' --report
line R13a3 "$TT" ';;;' 'hello' --report
check "R13a typeText types at the caret; through --line it fails as unsupported and onFail.output gets it" \
  "field R13a1 '\"helloX\"' && same R13a2 '{\"failure\":\"unsupported\",\"outcome\":\"failed\",\"rule\":0,\"stage\":\"output\",\"v\":1}' \
   && same R13a3 '{\"fallback\":true,\"outcome\":\"delivered\",\"rule\":1,\"v\":1}' && [ \"\$(cat '$EV/R13a.sent')\" = 'Y|unsupported' ]" \
  "R13a*.out R13a.sent"

# M live macOS items: real CGEventTap and AX, driven through System Events
if [ "${1:-}" = "--no-live" ] || [ "$(uname -s)" != Darwin ]; then
  sk "M1-M4 live macOS" "not Darwin or --no-live"
else
  cap 10 "$BIN" --probe > "$EV/M0.probe.json" 2>&1
  if grep -q '"trusted":true' "$EV/M0.probe.json"; then ok "M0 Accessibility granted to keypipe" "M0.probe.json"
  else ng "M0 Accessibility granted to keypipe" "grant it in System Settings > Privacy > Accessibility, see M0.probe.json"; fi

  LIVE="{\"rules\":[
   {\"trigger\":\"@@@\",\"when\":{\"focus\":\"textField\"},\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"},
   {\"trigger\":\";;;\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/M2.sent'\"}},
   {\"trigger\":\"///\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/M2b.sent'\"}},
   {\"hotkey\":\"ctrl+@\",\"when\":{\"focus\":\"textField\"},\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"},
   {\"trigger\":\"!!!\",\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/M6.sent'\"}}]}"
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
    osa "tell application \"TextEdit\" to set text of document \"$DOC\" to \"\"" >/dev/null
    if front_is_ours; then
      osa 'tell application "System Events" to keystroke "1xyz///"' >/dev/null
      sleep 2
      osa "tell application \"TextEdit\" to get text of document \"$DOC\"" > "$EV/M2b.text"
      check "M2b TextEdit: focus any rule 1xyz/// erases only the trigger, sends empty input" \
        "[ -f '$EV/M2b.sent' ] && [ ! -s '$EV/M2b.sent' ] && [ \"\$(cat '$EV/M2b.text')\" = 1xyz ]" "M2b.sent empty, M2b.text"
    else
      ng "M2b TextEdit" "our document lost focus before typing; not typed"
    fi
    osa "tell application \"TextEdit\" to set text of document \"$DOC\" to \"\"" >/dev/null
    if front_is_ours; then
      osa 'tell application "System Events" to keystroke "1hello"' >/dev/null
      sleep 1
      osa 'tell application "System Events" to keystroke "@" using control down' >/dev/null
      sleep 2
      osa "tell application \"TextEdit\" to get text of document \"$DOC\"" > "$EV/M5.text"
      check "M5 TextEdit: ctrl+@ hotkey uppercases the field without erasing" \
        "[ \"\$(cat '$EV/M5.text')\" = 1HELLO ] && grep -q 'keypipe matched ctrl+@' '$EV/daemon.log'" "M5.text, daemon.log"
    else
      ng "M5 TextEdit" "our document lost focus before typing; not typed"
    fi
    osa "tell application \"TextEdit\" to set text of document \"$DOC\" to \"\"" >/dev/null
    if front_is_ours; then
      # Shifted key: the event's stored string is "1", UCKeyTranslate yields "!".
      osa 'tell application "System Events" to keystroke "1xyz!!!"' >/dev/null
      sleep 2
      osa "tell application \"TextEdit\" to get text of document \"$DOC\"" > "$EV/M6.text"
      check "M6 TextEdit: shifted text trigger 1xyz!!! fires and erases only the trigger" \
        "[ -f '$EV/M6.sent' ] && [ \"\$(cat '$EV/M6.text')\" = 1xyz ]" "M6.sent, M6.text"
    else
      ng "M6 TextEdit" "our document lost focus before typing; not typed"
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

  if [ -d "/Applications/Google Chrome.app" ]; then
    # Chromium lands AXValue writes a few ms after accepting them; the write must still count.
    printf '%s' '<textarea id=t autofocus rows=4></textarea><script>t.focus()</script>' > "$EV/M7.html"
    osa "tell application \"Google Chrome\" to open location \"file://$EV/M7.html\"" >/dev/null
    osa 'tell application "Google Chrome" to activate' >/dev/null
    sleep 2
    osa 'tell application "System Events" to keystroke "hello@@@"' >/dev/null
    sleep 2
    cap 10 "$BIN" --probe > "$EV/M7.probe.json" 2>&1
    osa 'tell application "Google Chrome" to close (every tab of front window whose URL ends with "M7.html")' >/dev/null
    check "M7 Chrome textarea: hello@@@ becomes HELLO through a delayed AXValue write" \
      "grep -q '\"fieldText\":\"HELLO\"' '$EV/M7.probe.json' && grep -q 'keypipe apply replaceInput \"HELLO\"' '$EV/daemon.log' && ! grep -q 'apply-failed' '$EV/daemon.log'" "M7.probe.json, daemon.log"
  else
    sk "M7 Chrome textarea" "/Applications/Google Chrome.app absent"
  fi

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
