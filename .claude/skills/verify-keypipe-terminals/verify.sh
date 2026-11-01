#!/usr/bin/env bash
# Terminal parity for keypipe rules (replaceInput and output.shell) through the zsh line bridge.
# Usage: verify.sh [--doctor] [--no-live] [--only iterm2|wezterm|ghostty]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
EV="${KP_EVIDENCE:-$REPO/.verify-evidence/terminals-$RUN_ID}"
BIN="$REPO/.build/debug/keypipe"
WIDGET="$REPO/shell/keypipe.zsh"
WEZ=/Applications/WezTerm.app/Contents/MacOS/wezterm
ONLY=""; DOCTOR=0; LIVE=1
while [ $# -gt 0 ]; do
  case $1 in --doctor) DOCTOR=1 ;; --no-live) LIVE=0 ;; --only) ONLY=$2; shift ;; esac; shift
done
mkdir -p "$EV"
printf 'item\tstatus\tdetail\n' > "$EV/results.tsv"

PASS=0; FAIL=0; SKIP=0
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$EV/results.tsv"; }
ok() { PASS=$((PASS + 1)); echo "PASS $1 :: ${2:-}"; row "$1" PASS "${2:-}"; }
ng() { FAIL=$((FAIL + 1)); echo "FAIL $1 :: $2"; row "$1" FAIL "$2"; }
sk() { SKIP=$((SKIP + 1)); echo "SKIP $1 :: $2"; row "$1" SKIP "$2"; }
check() { if eval "$2"; then ok "$1" "$3"; else ng "$1" "$3"; fi; }
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }
osa() { osascript -e "$1" 2>&1; }
oneline() { [ -f "$1" ] && tr '\n' '|' < "$1" | cut -c1-400; }
is() { printf '%s' "$2" | cmp -s - "$EV/$1"; }

STARTED_PIDS=""
TMUX_SOCK="kpw-$$"
cleanup() {
  for p in $STARTED_PIDS; do kill -TERM "$p" 2>/dev/null; done
  # Why: an interactive zsh ignores SIGTERM; HUP is what a closed terminal sends.
  for f in "$EV"/*.pid; do [ -f "$f" ] && kill -HUP "$(cat "$f")" 2>/dev/null; done
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null
  [ -n "${IM_BEFORE:-}" ] && "$IMSEL" "$IM_BEFORE" > /dev/null 2>&1
  [ -f "$EV/results.tsv" ] || echo "FAIL cleanup removed evidence"
}
trap cleanup EXIT

{
  echo "repo=$REPO"
  echo "commit=$(git -C "$REPO" rev-parse --short HEAD 2>&1)"
  echo "uname=$(uname -a)"
  for a in iTerm WezTerm Ghostty; do
    echo "$a=$(defaults read "/Applications/$a.app/Contents/Info.plist" CFBundleShortVersionString 2>&1)"
  done
  echo "nvim=$(command -v nvim || echo absent)"
  echo "tmux=$(tmux -V 2>&1)"
  echo "widget=$([ -f "$WIDGET" ] && echo "$WIDGET" || echo absent)"
} > "$EV/env.txt" 2>&1
cat "$EV/env.txt"

# rules <id>: the JSON every harness shares. Only the side-effect path differs per item.
rules() {
  printf '%s' "{\"rules\":[
 {\"trigger\":\"@@@\",\"when\":{\"focus\":\"textField\"},\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"},
 {\"trigger\":\";;;\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/$1.sent'\"}},
 {\"trigger\":\"%%%\",\"when\":{\"focus\":\"textField\"},\"transform\":\"rev\",\"output\":\"replaceInput\"},
 {\"trigger\":\"^^^\",\"when\":{\"focus\":\"textField\",\"app\":[\"com.apple.TextEdit\"]},\"transform\":\"tr a-z A-Z\",\"output\":\"replaceInput\"},
 {\"trigger\":\"@@@\",\"output\":\"notify\"}]}"
}

# D doctor (read-only)
[ "$(uname -s)" = Darwin ] && ok "D0a macOS host" || ng "D0a macOS host" "uname is $(uname -s)"
[ -x "$BIN" ] && ok "D0b keypipe built" || ng "D0b keypipe built" "$BIN missing; run swift build"
command -v tmux >/dev/null && ok "D0g tmux present" || ng "D0g tmux present" "W items need tmux"
[ -f "$WIDGET" ] && ok "D0f zsh widget present" "$WIDGET" || sk "D0f zsh widget present" "$WIDGET absent; W and T items will fail"
OTHER=0
if pgrep -x keypipe >/dev/null; then
  OTHER=1; sk "D0c no other keypipe running" "pid $(pgrep -x keypipe | tr '\n' ' '); live items need make stop"
else ok "D0c no other keypipe running"; fi
for a in iTerm WezTerm Ghostty; do
  [ -d "/Applications/$a.app" ] && ok "D0d $a installed" || sk "D0d $a installed" "/Applications/$a.app absent"
done
command -v nvim >/dev/null && ok "D0e nvim present" || sk "D0e nvim present" "N items will skip"
if [ "$LIVE" = 1 ] && [ -x "$BIN" ]; then
  cap 10 "$BIN" --probe > "$EV/D0.probe.json" 2>&1
  grep -q '"trusted":true' "$EV/D0.probe.json" && ok "D0h Accessibility granted to keypipe" "D0.probe.json" \
    || ng "D0h Accessibility granted to keypipe" "grant it in System Settings > Privacy > Accessibility"
fi
if [ "$DOCTOR" = 1 ]; then
  echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"; [ "$FAIL" -eq 0 ]; exit
fi
[ -x "$BIN" ] || { echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"; exit 1; }

# B bridge contract: keypipe --line, the one-shot the widget calls. No daemon, no GUI.
rules B > "$EV/B.config.json"
cap 3 "$BIN" --config "$EV/B.config.json" --triggers > "$EV/B0.out" 2>&1
echo $? > "$EV/B0.exit"
BRIDGE=0
if [ "$(cat "$EV/B0.exit")" = 0 ] && grep -qx '@@@' "$EV/B0.out" && grep -qx ';;;' "$EV/B0.out"; then
  BRIDGE=1; ok "B0 --triggers lists the text triggers" "B0.out"
else
  ng "B0 --triggers lists the text triggers" "exit $(cat "$EV/B0.exit"), $(oneline "$EV/B0.out")"
fi
# line <id> <trigger> <app> <stdin>
line() {
  printf '%s' "$4" > "$EV/$1.in"
  cap 20 "$BIN" --config "$EV/B.config.json" --line "$2" --app "$3" < "$EV/$1.in" > "$EV/$1.out" 2> "$EV/$1.err"
  echo $? > "$EV/$1.exit"
}
exitis() { [ "$(cat "$EV/$1.exit")" = "$2" ]; }
IT=com.googlecode.iterm2
if [ "$BRIDGE" = 0 ]; then
  for i in "B1 replaceInput returns the new line" "B2 output.shell gets the line, line kept" "B3 rule only in JSON (rev) applies" \
    "B4 app-scoped rule does not match a terminal: exit 2, empty stdout" "B5 metacharacters pass byte-exact, nothing run" \
    "B6 Japanese line intact" "B7 failing stage keeps the line" "B8 shellTimeout bounds the call"; do
    ng "$i" "bridge not implemented (B0 failed)"
  done
else
  line B1 @@@ "$IT" "hello"
  check "B1 replaceInput returns the new line" "exitis B1 0 && is B1.out HELLO" "B1.out"
  line B2 ';;;' "$IT" "fix the flaky test"
  check "B2 output.shell gets the line, line kept" "exitis B2 0 && is B2.out 'fix the flaky test' && is B.sent 'fix the flaky test'" "B2.out, B.sent"
  line B3 '%%%' "$IT" "abc"
  check "B3 rule only in JSON (rev) applies" "exitis B3 0 && is B3.out cba" "B3.out"
  line B4 '^^^' "$IT" "hello"
  check "B4 app-scoped rule does not match a terminal: exit 2, empty stdout" "exitis B4 2 && [ ! -s '$EV/B4.out' ]" "B4.out"
  rm -f "$EV/B.sent"
  line B5 ';;;' "$IT" "a \$(touch '$EV/B5.pwned') \`id\` 'q' \"d\""
  check "B5 metacharacters pass byte-exact, nothing run" \
    "exitis B5 0 && cmp -s '$EV/B5.in' '$EV/B5.out' && cmp -s '$EV/B5.in' '$EV/B.sent' && [ ! -e '$EV/B5.pwned' ]" "B5.in, B5.out, B.sent"
  line B6 @@@ "$IT" "こんにちは abc"
  check "B6 Japanese line intact" "exitis B6 0 && is B6.out 'こんにちは ABC'" "B6.out"
  printf '%s' '{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"exit 3","output":"replaceInput"}]}' > "$EV/B7.config.json"
  printf '%s' hello > "$EV/B7.in"
  cap 20 "$BIN" --config "$EV/B7.config.json" --line @@@ --app "$IT" < "$EV/B7.in" > "$EV/B7.out" 2> "$EV/B7.err"; echo $? > "$EV/B7.exit"
  check "B7 failing stage keeps the line" "exitis B7 0 && is B7.out hello" "B7.out, B7.err"
  printf '%s' '{"shellTimeout":1,"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"sleep 5","output":"replaceInput"}]}' > "$EV/B8.config.json"
  printf '%s' hello > "$EV/B8.in"
  t0=$(date +%s)
  cap 20 "$BIN" --config "$EV/B8.config.json" --line @@@ --app "$IT" < "$EV/B8.in" > "$EV/B8.out" 2> "$EV/B8.err"; echo $? > "$EV/B8.exit"
  t1=$(date +%s)
  check "B8 shellTimeout bounds the call" "exitis B8 0 && is B8.out hello && [ $((t1 - t0)) -le 3 ]" "$((t1 - t0))s, B8.out"
fi

# J background output.shell: the caller returns at once; the job reports to jobs.log and notifies on failure.
export XDG_STATE_HOME="$EV/state"
JLOG="$EV/state/keypipe/jobs.log"
jcfg() {
  printf '%s' "{\"rules\":[{\"trigger\":\"&&&\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"$2\",\"background\":true}}]}" > "$EV/$1.config.json"
}
jlog() { [ -f "$JLOG" ] && grep -qF -- "$1" "$JLOG"; }
if [ "$BRIDGE" = 0 ]; then
  ng "J1 bridge returns before a background webhook finishes" "bridge not implemented (B0 failed)"
  ng "J2 failing background webhook is logged and notified" "bridge not implemented (B0 failed)"
else
  jcfg J1 "sleep 2; printf %s \\\"\$1\\\" > '$EV/J1.sent'"
  printf '%s' 'send me' > "$EV/J1.in"
  t0=$(date +%s)
  cap 20 "$BIN" --config "$EV/J1.config.json" --line '&&&' --app "$IT" < "$EV/J1.in" > "$EV/J1.out" 2> "$EV/J1.err"; echo $? > "$EV/J1.exit"
  t1=$(date +%s); early=$([ -e "$EV/J1.sent" ] && echo present || echo absent)
  sleep 4
  check "J1 bridge returns before a background webhook finishes" \
    "exitis J1 0 && is J1.out 'send me' && [ $((t1 - t0)) -le 1 ] && [ $early = absent ] && is J1.sent 'send me' && jlog 'output-shell exit 0'" \
    "$((t1 - t0))s, sent at return: $early, jobs.log=$(oneline "$JLOG")"
  jcfg J2 "exit 7"
  printf '%s' 'send me' > "$EV/J2.in"
  cap 20 "$BIN" --config "$EV/J2.config.json" --line '&&&' --app "$IT" < "$EV/J2.in" > "$EV/J2.out" 2> "$EV/J2.err"; echo $? > "$EV/J2.exit"
  sleep 2
  check "J2 failing background webhook is logged and notified" \
    "exitis J2 0 && is J2.out 'send me' && jlog 'output-shell exit 7' && jlog 'apply notify'" "jobs.log=$(oneline "$JLOG")"
fi
jcfg J3 "sleep 2; printf %s \\\"\$1\\\" > '$EV/J3.sent'"
printf '%s' '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"note"}' > "$EV/J3.context.json"
t0=$(date +%s)
cap 20 "$BIN" --config "$EV/J3.config.json" --context "$EV/J3.context.json" --smoke-feed '&&&' > "$EV/J3.out" 2>&1; echo $? > "$EV/J3.exit"
t1=$(date +%s); early=$([ -e "$EV/J3.sent" ] && echo present || echo absent)
sleep 4
check "J3 editor fire returns before a background webhook finishes, text still sent" \
  "[ $((t1 - t0)) -le 1 ] && [ $early = absent ] && is J3.sent note" "$((t1 - t0))s, sent at return: $early, $(oneline "$EV/J3.out")"

# J4 the job outlives the terminal that started it: the tmux session (pane process group) dies right after the call.
if [ "$BRIDGE" = 0 ] || ! command -v tmux >/dev/null; then
  ng "J4 background job survives closing the terminal" "bridge not implemented (B0 failed) or tmux absent"
else
  jcfg J4 "sleep 3; printf %s \\\"\$1\\\" > '$EV/J4.sent'"
  printf '%s' 'keep going' > "$EV/J4.in"
  tmux -L "$TMUX_SOCK" new-session -d -s J4 \
    "XDG_STATE_HOME='$EV/state' '$BIN' --config '$EV/J4.config.json' --line '&&&' --app $IT < '$EV/J4.in' > '$EV/J4.out' 2> '$EV/J4.err'; touch '$EV/J4.returned'; sleep 30"
  for _ in $(seq 1 20); do [ -f "$EV/J4.returned" ] && break; sleep 0.25; done
  tmux -L "$TMUX_SOCK" kill-session -t J4 2>/dev/null
  sleep 5
  check "J4 background job survives closing the terminal" "is J4.out 'keep going' && is J4.sent 'keep going'" "J4.out, J4.sent"
fi

# J5/J6 backgroundTimeout (top level, like shellTimeout) ends a job that runs too long.
printf '%s' "{\"backgroundTimeout\":2,\"rules\":[{\"trigger\":\"&&&\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"sleep 10; printf %s \\\"\$1\\\" > '$EV/J5.sent'\",\"background\":true}}]}" > "$EV/J5.config.json"
printf '%s' '{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"slow"}' > "$EV/J5.context.json"
cap 20 "$BIN" --config "$EV/J5.config.json" --context "$EV/J5.context.json" --smoke-feed '&&&' > "$EV/J5.out" 2>&1; echo $? > "$EV/J5.exit"
sleep 5
check "J5 backgroundTimeout 2 ends a 10 s job: nothing sent, timeout logged and notified" \
  "[ ! -e '$EV/J5.sent' ] && jlog 'output-shell timeout 2' && jlog 'apply notify'" "jobs.log=$(oneline "$JLOG"), $(oneline "$EV/J5.out")"
printf '%s' '{"backgroundTimeout":0,"rules":[{"trigger":"&&&","output":"notify"}]}' > "$EV/J6.config.json"
cap 5 "$BIN" --config "$EV/J6.config.json" --context "$EV/J5.context.json" --smoke-feed x > "$EV/J6.out" 2>&1; echo $? > "$EV/J6.exit"
check "J6 backgroundTimeout 0 is rejected: invalid config: backgroundTimeout must be positive" \
  "exitis J6 1 && grep -q 'invalid config: backgroundTimeout must be positive' '$EV/J6.out'" "$(oneline "$EV/J6.out")"

# F hazard: the daemon must not use a terminal's AX field (it is the whole pane).
# Terminals are recognized by owning a pty master (/dev/ptmx), so an unknown bundle id counts too.
feed() {
  printf '%s' "$2" > "$EV/$1.context.json"
  cap 20 "$BIN" --config "$EV/$1.config.json" --context "$EV/$1.context.json" --smoke-feed @@@ > "$EV/$1.out" 2>&1
  echo $? > "$EV/$1.exit"
}
PANE='LAST LOGIN secret-token-123\nkpv> hello'
for spec in "iterm2 com.googlecode.iterm2 true" "wezterm com.github.wez.wezterm true" "ghostty com.mitchellh.ghostty true" \
  "unknown com.example.someterm true" "textedit com.apple.TextEdit false"; do
  set -- $spec
  id="F-$1"
  printf '%s' "{\"rules\":[{\"trigger\":\"@@@\",\"when\":{\"focus\":\"textField\"},\"output\":{\"shell\":\"printf %s \\\"\$1\\\" > '$EV/$id.sent'\"}}]}" > "$EV/$id.config.json"
  feed "$id" "{\"app\":\"$2\",\"ownsPty\":$3,\"focusIsTextField\":true,\"fieldText\":\"$PANE\"}"
  if [ "$1" = textedit ]; then
    check "F2 control: TextEdit field is sent whole (proves F1 can see a leak)" "[ -f '$EV/$id.sent' ] && grep -q secret-token '$EV/$id.sent'" "$id.sent"
  else
    check "F1-$1 daemon does not send or erase a terminal pane" \
      "[ ! -e '$EV/$id.sent' ] && ! grep -q 'keypipe erase [1-9]' '$EV/$id.out'" "$(oneline "$EV/$id.out")"
  fi
done

# W widget in zsh under tmux: real ZLE, no GUI, no keystrokes into the user's windows.
{
  echo "export KEYPIPE_BIN='$BIN' KEYPIPE_CONFIG='$EV/W.config.json' KEYPIPE_APP=com.googlecode.iterm2"
  echo "[ -f '$WIDGET' ] && source '$WIDGET'"
} > "$EV/kp.env"
rules W > "$EV/W.config.json"
# wdrive <id> <keys...>: "=text" is typed literally, anything else is a tmux key name; Enter comes last.
wdrive() {
  local id=$1; shift
  tmux -L "$TMUX_SOCK" new-session -d -s "$id" -x 120 -y 20 "/bin/sh '$HERE/session.sh' '$EV' '$id' zsh"
  for _ in $(seq 1 20); do [ -f "$EV/$id.recv" ] && break; sleep 0.25; done
  for k in "$@"; do
    # Why: tmux reads an argument ending in ";" as a command separator, so literal text goes as hex bytes.
    case $k in =*) tmux -L "$TMUX_SOCK" send-keys -t "$id" -H $(printf '%s' "${k#=}" | od -An -tx1) ;;
      *) tmux -L "$TMUX_SOCK" send-keys -t "$id" "$k" ;; esac
    sleep 0.3
  done
  sleep 1; tmux -L "$TMUX_SOCK" send-keys -t "$id" Enter; sleep 0.5
  tmux -L "$TMUX_SOCK" capture-pane -p -t "$id" > "$EV/$id.pane"
  tmux -L "$TMUX_SOCK" kill-session -t "$id" 2>/dev/null
}
if ! command -v tmux >/dev/null; then sk "W items" "tmux absent"; else
  wdrive W1 '=hello@@@'
  check "W1 hello@@@ becomes HELLO in the zsh buffer" "is W1.recv 'HELLO
'" "W1.recv=$(oneline "$EV/W1.recv")"
  wdrive W2 '=fix the flaky test;;;'
  check "W2 ;;; sends the line through output.shell, line kept without trigger" \
    "is W2.recv 'fix the flaky test
' && is W.sent 'fix the flaky test'" "W2.recv=$(oneline "$EV/W2.recv") sent=$(oneline "$EV/W.sent")"
  wdrive W3 '=abc%%%'
  check "W3 rule that exists only in JSON (rev) applies" "is W3.recv 'cba
'" "W3.recv=$(oneline "$EV/W3.recv")"
  wdrive W4 '=marker' Enter '=hello@@@'
  check "W4 previous line and prompt stay out of the input" "is W4.recv 'marker
HELLO
'" "W4.recv=$(oneline "$EV/W4.recv")"
  wdrive W5 '=hello@@'
  check "W5 incomplete trigger leaves the line alone" "is W5.recv 'hello@@
'" "W5.recv=$(oneline "$EV/W5.recv")"
  wdrive W6 '=ab cd' Left Left Left '=@@@'
  check "W6 trigger mid-line: whole line minus trigger is the input" "is W6.recv 'AB CD
'" "W6.recv=$(oneline "$EV/W6.recv")"
  wdrive W7 '=hello^^^'
  check "W7 rule that does not match this app keeps the trigger" "is W7.recv 'hello^^^
'" "W7.recv=$(oneline "$EV/W7.recv")"
fi

# L/T live: the real daemon with the same JSON, keystrokes into windows this run opens.
if [ "$LIVE" = 0 ]; then
  sk "L/T/N live" "--no-live"
elif [ "$OTHER" = 1 ]; then
  sk "L/T/N live" "another keypipe is running; make stop"
else
  rules L > "$EV/live.config.json"
  sed -i '' "s|KEYPIPE_CONFIG='[^']*'|KEYPIPE_CONFIG='$EV/live.config.json'|; s|KEYPIPE_APP=[^ ]*|KEYPIPE_APP=|" "$EV/kp.env"
  "$BIN" --config "$EV/live.config.json" > "$EV/daemon.log" 2>&1 &
  DPID=$!; STARTED_PIDS="$STARTED_PIDS $DPID"; echo "$DPID" > "$EV/daemon.daemonpid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'keypipe started' "$EV/daemon.log" && break; sleep 0.5; done
  if grep -q 'keypipe started' "$EV/daemon.log"; then ok "L0 daemon started" "daemon.log"
  else ng "L0 daemon started" "no 'keypipe started' within 5s"; fi

  # Why: a Japanese IME turns System Events keystrokes into uncommitted kana (marker became まｒけｒ on
  # 2026-11-01), and a new window may get its own input source, so ABC is selected before every typing step.
  IMSEL="$EV/imsel"
  swiftc -O -o "$IMSEL" "$REPO/.claude/skills/verify-keypipe-rules/probes/imsel.swift" > "$EV/imsel.build.log" 2>&1
  IM_BEFORE=$("$IMSEL" 2>/dev/null | sed -n 's/^before=//p')
  echo "input source before: $IM_BEFORE" >> "$EV/env.txt"
  abc() { "$IMSEL" com.apple.keylayout.ABC > /dev/null 2>&1; }
  front_title() { osa 'tell application "System Events" to get name of front window of (first application process whose frontmost is true)'; }
  ours() {
    case "$(front_title)" in *"kpv-$1"*) ;; *) return 1 ;; esac
    cap 10 "$BIN" --probe 2>/dev/null | grep -q "\"app\":\"$2\""
  }
  spawn() {
    case $1 in
    iterm2)
      osascript -e 'on run argv' -e 'tell application "iTerm" to create window with default profile command (item 1 of argv)' \
        -e 'end run' "/bin/sh $HERE/session.sh $EV $2 $3" > "$EV/$2.spawn.log" 2>&1
      osa 'tell application "iTerm" to activate' >/dev/null ;;
    wezterm)
      "$WEZ" start --always-new-process -- /bin/sh "$HERE/session.sh" "$EV" "$2" "$3" > "$EV/$2.spawn.log" 2>&1 &
      local wpid=$!; STARTED_PIDS="$STARTED_PIDS $wpid"
      # Why: a process started from a background shell is not activated; raise ours by pid,
      # not by app name, because the user's own WezTerm may also be running.
      sleep 2
      osa "tell application \"System Events\" to set frontmost of (first process whose unix id is $wpid) to true" >/dev/null ;;
    ghostty)
      open -na /Applications/Ghostty.app --args --quit-after-last-window-closed=true \
        -e /bin/sh "$HERE/session.sh" "$EV" "$2" "$3" > "$EV/$2.spawn.log" 2>&1 ;;
    esac
    # Why: a second Ghostty instance from open -na sometimes needs more than 10 s to show its window.
    for _ in $(seq 1 40); do ours "$2" "$4" && return 0; sleep 0.5; done
    return 1
  }
  close_session() { [ -f "$EV/$1.pid" ] && kill -HUP "$(cat "$EV/$1.pid")" 2>/dev/null; sleep 1; }
  key() { osa "tell application \"System Events\" to $1" >/dev/null; }
  daemon_silent() { ! grep -q 'keypipe erase [1-9]' "$EV/$1.delta.log" && ! grep -q 'keypipe apply' "$EV/$1.delta.log"; }

  # typed <term> <bundle> <id> <keys>: marker line, then <keys>, then Return.
  typed() {
    local t=$1 b=$2 id=$3
    if ! spawn "$t" "$id" zsh "$b"; then ng "$id window" "kpv-$id never frontmost as $b; nothing typed"; close_session "$id"; return 1; fi
    for _ in $(seq 1 10); do [ -f "$EV/$id.recv" ] && break; sleep 0.5; done
    cap 10 "$BIN" --probe > "$EV/$id.before.probe.json" 2>&1
    ours "$id" "$b" || { ng "$id typing" "focus left our window"; close_session "$id"; return 1; }
    abc
    key 'keystroke "marker"'; key 'key code 36'; sleep 1
    local n0; n0=$(wc -l < "$EV/daemon.log")
    ours "$id" "$b" || { ng "$id typing" "focus left our window"; close_session "$id"; return 1; }
    key "keystroke \"$4\""; sleep 2
    cap 10 "$BIN" --probe > "$EV/$id.after.probe.json" 2>&1
    ours "$id" "$b" && key 'key code 36'; sleep 1
    tail -n +"$((n0 + 1))" "$EV/daemon.log" > "$EV/$id.delta.log"
    close_session "$id"
  }
  drive() {
    local t=$1 b=$2
    if typed "$t" "$b" "T-$t" 'hello@@@'; then
      ok "T0-$t probe recorded" "$(grep -o '"focus":"[A-Za-z]*"' "$EV/T-$t.before.probe.json")"
      ok "T1-$t daemon transcript recorded" "$(oneline "$EV/T-$t.delta.log")"
      check "T2-$t hello@@@ at the prompt becomes HELLO, line only, nothing run, daemon silent" \
        "is T-$t.recv 'marker
HELLO
' && daemon_silent T-$t && kill -0 $DPID" "recv=$(oneline "$EV/T-$t.recv") log=$(oneline "$EV/T-$t.delta.log")"
    fi
    # Why: on this Mac a typed space flips the input source back to ATOK (measured 2026-11-01 in iTerm2),
    # so the live line has no spaces; W2 covers spaces through real ZLE under tmux.
    if typed "$t" "$b" "S-$t" 'fix-the-flaky-test;;;'; then
      check "T3-$t ;;; sends exactly the line, no pane text, line kept, daemon silent" \
        "is S-$t.recv 'marker
fix-the-flaky-test
' && is L.sent 'fix-the-flaky-test' && daemon_silent S-$t" "recv=$(oneline "$EV/S-$t.recv") sent=$(oneline "$EV/L.sent")"
      rm -f "$EV/L.sent"
    fi
    if ! command -v nvim >/dev/null; then sk "N-$t nvim insert" "nvim absent"; return; fi
    local id="N-$t"
    spawn "$t" "$id" nvim "$b" || { sk "N-$t nvim insert" "kpv-$id never frontmost (record-only item)"; close_session "$id"; return; }
    sleep 1
    local n0; n0=$(wc -l < "$EV/daemon.log")
    abc
    key 'keystroke "hello@@@"'; sleep 2
    ours "$id" "$b" && { key 'key code 53'; key 'keystroke ":wq"'; key 'key code 36'; }; sleep 1
    tail -n +"$((n0 + 1))" "$EV/daemon.log" > "$EV/$id.delta.log"
    ok "N-$t nvim insert recorded (not a pass criterion)" "file=$(oneline "$EV/$id.recv") log=$(oneline "$EV/$id.delta.log")"
    close_session "$id"
  }
  if grep -q 'keypipe started' "$EV/daemon.log"; then
    for spec in "iterm2 iTerm com.googlecode.iterm2" "wezterm WezTerm com.github.wez.wezterm" "ghostty Ghostty com.mitchellh.ghostty"; do
      set -- $spec
      [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && continue
      if [ -d "/Applications/$2.app" ]; then drive "$1" "$3"; else sk "T-$1" "/Applications/$2.app absent"; fi
    done
    kill -0 "$DPID" 2>/dev/null && ok "L1 daemon alive after all terminals" || ng "L1 daemon alive after all terminals" "see daemon.log"
  fi
fi

echo "summary pass=$PASS fail=$FAIL skip=$SKIP evidence=$EV"
[ "$FAIL" -eq 0 ]
