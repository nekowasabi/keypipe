#!/bin/bash
# Bounded-exhaustive check that a failed send never loses the prompt and always tells the user why.
# P1 runs the real keypipe background job over every transform x output x onFail.output outcome.
# P2 runs the real shell/herdr-claude.sh over every dictation x selection x clipboard x herdr-app
# result x VOICE_SWITCH_APP, against stubs. P3 joins them: keypipe --rule running herdr-claude.sh.
# Exit 0: every property holds, apart from the known findings listed in KNOWN.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
keypipe=$root/.build/debug/keypipe
script=$root/shell/herdr-claude.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
KNOWN=""
# Why: P1 runs its cases in background subshells, so counts live in files, not variables.
bad() { echo "FAIL $1: $2" | tee -a "$work/fails"; }
finding() {
  if [[ " $KNOWN " == *" $1 "* ]]; then echo "$1" >>"$work/seen"; else bad "$1" "$2"; fi
}

(cd "$root" && swift build >/dev/null 2>&1) || { echo "FAIL swift build"; exit 1; }

# P1 ------------------------------------------------------------------------------------------
trigger=ctrl+alt+cmd+k
long200=$(printf 'x%.0s' $(seq 200))
t_script() {
  case $1 in
    ok) echo 'printf "T:%s" "$1"' ;;
    fail) echo 'echo "tr reason" >&2; exit 3' ;;
  esac
}
# Each output outcome: script, then KEYPIPE_FAILURE token, then the reason the notification must carry.
o_script() {
  case $1 in
    ok) echo 'exit 0' ;;
    failR) echo 'echo first >&2; echo "  out \"引用\" reason  " >&2; exit 4' ;;
    fail0) echo 'exit 5' ;;
    failML) echo 'printf "a\nlast line\n\n\n" >&2; exit 6' ;;
    failLong) echo 'i=0; s=; while [ $i -lt 300 ]; do s=${s}x; i=$((i+1)); done; echo "$s" >&2; exit 8' ;;
    timeout) echo 'exec /bin/sleep 5' ;;
  esac
}
o_token() {
  case $1 in failR) echo "exit 4" ;; fail0) echo "exit 5" ;; failML) echo "exit 6" ;;
    failLong) echo "exit 8" ;; timeout) echo timeout ;; esac
}
long300=$(printf 'x%.0s' $(seq 300))
# The transcript keeps the whole last stderr line; the notification keeps its first 200 characters.
o_reason() {
  case $1 in failR) echo 'out "引用" reason' ;; failML) echo "last line" ;; failLong) echo "$long300" ;; esac
}
o_notified_reason() { local r; r=$(o_reason "$1"); printf '%s' "${r:0:200}"; }
f_script() {
  case $1 in
    ok) echo 'printf "%s" "$KEYPIPE_FAILURE" > "$KP_OUT"' ;;
    failR) echo 'printf "%s" "$KEYPIPE_FAILURE" > "$KP_OUT"; echo "fb reason" >&2; exit 7' ;;
  esac
}
json() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
message() { [ -n "$2" ] && printf '%s: %s' "$1" "$2" || printf '%s' "$1"; }

p1_case() {
  local t=$1 o=$2 f=$3 dir=$work/p1/$1-$2-$3
  mkdir -p "$dir"
  local rule="{ \"name\": \"r\", \"hotkey\": \"$trigger\", \"when\": { \"focus\": \"any\" }"
  [ "$t" = none ] || rule+=", \"transform\": $(json "$(t_script "$t")")"
  rule+=", \"output\": { \"shell\": $(json "$(o_script "$o")"), \"background\": true }"
  [ "$f" = none ] || rule+=", \"onFail\": { \"output\": { \"shell\": $(json "$(f_script "$f")") } }"
  printf '{ "shellTimeout": 1, "rules": [ %s } ] }' "$rule" >"$dir/config.json"
  # Why: PATH without osascript, so the job's notifications reach the transcript but not the screen.
  printf 'note' | env -i HOME="$HOME" PATH=/nonexistent KP_OUT="$dir/kp_out" \
    XDG_STATE_HOME="$dir/state" "$keypipe" --config "$dir/config.json" --rule r --report \
    >"$dir/report" 2>"$dir/err"
  local log=$dir/state/keypipe/jobs.log
  for _ in $(seq 100); do grep -q 'keypipe job done' "$log" 2>/dev/null && break; sleep 0.05; done
  local id="P1 t=$t o=$o f=$f"
  grep -q '"outcome":"started"' "$dir/report" || { bad "$id" "report: $(cat "$dir/report" "$dir/err")"; return; }
  grep -q 'keypipe job done' "$log" 2>/dev/null || { bad "$id" "job never finished"; return; }
  local lines notes want_note="" want_kp="" stderr_line="" reason
  lines=$(cut -d' ' -f3- "$log")
  notes=$(grep '^keypipe apply notify ' <<<"$lines")
  reason=$(o_reason "$o")
  if [ "$t" = fail ]; then
    want_note="r transform failed: exit 3: tr reason"
    stderr_line='keypipe transform stderr "tr reason"'
    grep -q 'output-shell' <<<"$lines" && bad "$id" "output ran after a failed transform"
  elif [ "$o" != ok ]; then
    [ -n "$reason" ] && stderr_line="keypipe output-shell stderr $(json "$reason")"
    case $f in
      none) want_note="r output failed: $(message "$(o_token "$o")" "$(o_notified_reason "$o")")" ;;
      ok) want_kp=$(o_token "$o") ;;
      failR) want_kp=$(o_token "$o"); want_note="r output failed: exit 7: fb reason"
        grep -qxF 'keypipe fallback output-shell stderr "fb reason"' <<<"$lines" ||
          bad "$id" "no fallback stderr line" ;;
    esac
  fi
  if [ -n "$want_note" ]; then
    [ "$notes" = "keypipe apply notify $(json "$want_note")" ] ||
      bad "$id" "want exactly: notify $(json "$want_note"); got: $notes"
  else
    [ -z "$notes" ] || bad "$id" "notified a fire that did not fail: $notes"
  fi
  local primary_stderr
  primary_stderr=$(grep -E '^keypipe (transform|output-shell) stderr ' <<<"$lines")
  [ "$primary_stderr" = "$stderr_line" ] ||
    bad "$id" "stderr transcript: want '$stderr_line', got '$primary_stderr'"
  if [ -n "$want_kp" ]; then
    [ "$(cat "$dir/kp_out" 2>/dev/null)" = "$want_kp" ] ||
      bad "$id" "KEYPIPE_FAILURE was '$(cat "$dir/kp_out" 2>/dev/null)', want '$want_kp'"
  fi
}

for t in none ok fail; do
  for o in ok failR fail0 failML failLong timeout; do
    for f in none ok failR; do
      [ "$t" = fail ] && [ "$o" != ok ] && continue
      [ "$o" = ok ] && [ "$f" != none ] && continue
      p1_case "$t" "$o" "$f" &
    done
  done
done
wait
p1_runs=$(find "$work/p1" -name report | wc -l | tr -d ' ')

# P2 ------------------------------------------------------------------------------------------
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/herdr-app" <<'EOF'
#!/bin/sh
echo call >>"$STUB_CALLS"
# Real herdr-app reads a JSON-looking --task as JSON and hands the task to claude as an argument
# (F3), so the only accepted shape is one JSON object with a string task and argv claude --.
[ "$#" = 3 ] && [ "$1 $2" = "do tab.new" ] || { echo '{"error":"not one JSON object"}'; exit 2; }
fields=$(/usr/bin/osascript -l JavaScript -e 'function run(a) {
  var o = JSON.parse(a[0].slice(1));
  if (typeof o.task !== "string") return "BAD";
  return JSON.stringify(o.argv) + "\n" + o.task;
}' "x$3") || { echo '{"error":"bad json"}'; exit 2; }
printf '%s' "${fields%%
*}" >"$STUB_ARGV"
printf '%s' "${fields#*
}" >"$STUB_TASK"
/bin/sleep "${STUB_HERDR_DELAY:-0}"
case $STUB_MODE in
  ok) echo '{"tab":"tb1","terminal":"t1"}' ;;
  fail1) echo '{"error":"x"}'; exit 1 ;;
  failML) printf '{\n  "error": "no window"\n}\n'; exit 1 ;;
  fail0) exit 1 ;;
esac
EOF
printf '#!/bin/sh\ncat "$STUB_CLIP"\n' >"$bin/pbpaste"
printf '#!/bin/sh\ncat >"$STUB_CLIP"\n' >"$bin/pbcopy"
cat >"$bin/osascript" <<'EOF'
#!/bin/sh
[ "${STUB_COPY:-ok}" = ok ] || exit 1
/bin/sleep "${STUB_COPY_DELAY:-0}"
cp "$STUB_SELECTION" "$STUB_CLIP"
EOF
printf '#!/bin/sh\necho "open $*" >>"$STUB_CALLS"\n' >"$bin/open"
printf '#!/bin/sh\n[ -z "${SLEEP:-}" ] || exec /bin/sleep "$@"\n' >"$bin/sleep"
chmod +x "$bin"/*

tricky=$(printf -- "-x 'q' \"dq\" \$HOME \`b\` \$(echo hi)\n日本語 --folder /tmp")
dictations=("" "指示" "--folder /tmp -x")
selections=("" "body" "$tricky" $'line\n')
olds=("OLD" $'keep\n')
p2_runs=0

p2_case() {
  local d=$1 s=$2 old=$3 mode=$4 app=$5 c=$work/p2
  rm -rf "$c"; mkdir -p "$c"
  export STUB_CALLS=$c/calls STUB_ARGS=$c/args STUB_ARGV=$c/argv STUB_TASK=$c/task
  export STUB_CLIP=$c/clip STUB_SELECTION=$c/sel STUB_MODE=$mode
  printf '%s' "$s" >"$STUB_SELECTION"
  printf '%s' "$old" >"$STUB_CLIP"
  local herdr=$bin/herdr-app
  [ "$mode" = missing ] && herdr=$bin/no-such-herdr-app
  printf '%s' "$d" | env ${app:+VOICE_SWITCH_APP=$app} PATH="$bin:/usr/bin:/bin" HERDR_BIN="$herdr" \
    "$script" 2>"$c/err"
  local code=$? id="P2 d=$(json "$d") s=$(json "$s") old=$(json "$old") herdr=$mode app=${app:-unset}"
  p2_runs=$((p2_runs + 1))
  # Why: $(cat) and $(pbpaste) drop trailing newlines; the prompt is defined on what they return.
  local dd ss prompt
  dd=$(printf '%s' "$d"); ss=$(printf '%s' "$s")
  if [ -n "$dd" ] && [ -n "$ss" ]; then prompt=$(printf '%s\n\n%s' "$dd" "$ss"); else prompt=$dd$ss; fi
  local calls=0
  [ -f "$STUB_CALLS" ] && calls=$(grep -c '^call$' "$STUB_CALLS")
  if [ -n "$app" ]; then
    [ "$(head -1 "$STUB_CALLS" 2>/dev/null)" = "open -b $app" ] || bad "$id" "app not brought forward first"
  elif grep -q '^open' "$STUB_CALLS" 2>/dev/null; then
    bad "$id" "open ran without VOICE_SWITCH_APP"
  fi
  if [ -z "$prompt" ]; then
    [ "$code" = 3 ] && [ "$calls" = 0 ] || bad "$id" "empty prompt: exit $code, herdr calls $calls"
    cmp -s <(printf '%s' "$old") "$STUB_CLIP" || finding F1 "$id clipboard not restored"
    return
  fi
  [ "$calls" -le 1 ] || bad "$id" "herdr-app called $calls times"
  if [ "$calls" = 1 ]; then
    [ "$(cat "$STUB_ARGV")" = '["claude","--"]' ] || bad "$id" "argv $(cat "$STUB_ARGV")"
    cmp -s <(printf '%s' "$prompt") "$STUB_TASK" || bad "$id" "--task is not the prompt: $(cat "$STUB_TASK")"
  fi
  if [ "$mode" = ok ]; then
    [ "$code" = 0 ] || bad "$id" "exit $code: $(cat "$c/err")"
    cmp -s <(printf '%s' "$old") "$STUB_CLIP" || finding F1 "$id clipboard not restored"
  else
    [ "$code" = 1 ] || bad "$id" "exit $code, want 1"
    cmp -s <(printf '%s' "$prompt") "$STUB_CLIP" || bad "$id" "prompt not left on the clipboard"
    local lines last
    lines=$(grep -c . "$c/err")
    last=$(grep . "$c/err" | tail -1)
    [ "$lines" = 1 ] && [[ $last == "herdr-claude: prompt copied to the clipboard; tab.new failed"* ]] ||
      bad "$id" "stderr is not one reason line: $(cat "$c/err")"
  fi
}

for old in "${olds[@]}"; do
  for d in "${dictations[@]}"; do
    for s in "${selections[@]}"; do
      for mode in ok fail1 failML fail0 missing; do
        for app in "" com.apple.TextEdit; do p2_case "$d" "$s" "$old" "$mode" "$app"; done
      done
    done
  done
done

# P3 ------------------------------------------------------------------------------------------
p3_runs=0
for mode in failML missing ok; do
  c=$work/p3-$mode
  mkdir -p "$c"
  herdr=$bin/herdr-app
  [ "$mode" = missing ] && herdr=$bin/no-such-herdr-app
  printf '{ "rules": [ { "name": "herdr-claude", "hotkey": "ctrl+alt+cmd+j", "when": { "focus": "any" },
    "output": { "shell": "PATH=%s:/usr/bin:/bin HERDR_BIN=%s %s", "background": true } } ] }' \
    "$bin" "$herdr" "$script" >"$c/config.json"
  printf 'body' >"$c/sel"
  printf 'OLD' >"$c/clip"
  printf '要約して' | env -i HOME="$HOME" PATH=/nonexistent STUB_MODE=$mode STUB_CALLS=$c/calls \
    STUB_ARGS=$c/args STUB_ARGV=$c/argv STUB_TASK=$c/task STUB_CLIP=$c/clip STUB_SELECTION=$c/sel \
    XDG_STATE_HOME=$c/state "$keypipe" --config "$c/config.json" --rule herdr-claude --report >/dev/null 2>&1
  log=$c/state/keypipe/jobs.log
  for _ in $(seq 100); do grep -q 'keypipe job done' "$log" 2>/dev/null && break; sleep 0.05; done
  p3_runs=$((p3_runs + 1))
  note=$(grep 'apply notify' "$log" 2>/dev/null)
  if [ "$mode" = ok ]; then
    [ -z "$note" ] && [ "$(cat "$c/task" 2>/dev/null)" = "$(printf '要約して\n\nbody')" ] ||
      bad "P3 herdr=$mode" "jobs.log: $(cat "$log" 2>/dev/null)"
  else
    [[ $note == *'output failed: exit 1: herdr-claude: prompt copied to the clipboard; tab.new failed'* ]] &&
      [ "$(cat "$c/clip")" = "$(printf '要約して\n\nbody')" ] ||
      bad "P3 herdr=$mode" "notify: $note; clipboard: $(cat "$c/clip")"
  fi
done

# P4 ------------------------------------------------------------------------------------------
# Two sends gap seconds apart. The Cmd+C stub lands 0.3 s late, as the real one does, and the
# real sleep 0.2 runs; each send must carry the selection and the old clipboard must come back.
p4_runs=0
for gap in 0.05 0.1 0.2 0.3 0.4 0.6; do
  c=$work/p4
  rm -rf "$c"; mkdir -p "$c"
  printf 'SEL' >"$c/sel"
  printf 'OLD' >"$c/clip"
  for who in A B; do
    printf '%s' "$who" | env STUB_MODE=ok STUB_CALLS=$c/calls STUB_ARGS=$c/args STUB_ARGV=$c/argv.$who \
      STUB_TASK=$c/task.$who STUB_CLIP=$c/clip STUB_SELECTION=$c/sel STUB_COPY_DELAY=0.3 \
      STUB_HERDR_DELAY=0.5 PATH="$bin:/usr/bin:/bin" HERDR_BIN="$bin/herdr-app" \
      SLEEP=real "$script" 2>/dev/null &
    /bin/sleep "$gap"
  done
  wait
  p4_runs=$((p4_runs + 1))
  for who in A B; do
    [ "$(cat "$c/task.$who" 2>/dev/null)" = "$(printf '%s\n\nSEL' "$who")" ] ||
      bad "P4 gap=$gap" "send $who carried '$(cat "$c/task.$who" 2>/dev/null)'"
  done
  [ "$(cat "$c/clip")" = OLD ] || bad "P4 gap=$gap" "clipboard ended as '$(cat "$c/clip")'"
done

# P5 ------------------------------------------------------------------------------------------
# The Cmd+C fails (no Accessibility for System Events): the send stops with the reason, never
# sends the dictation alone as if nothing had been selected.
p5_runs=0
for d in "" "指示"; do
  c=$work/p5
  rm -rf "$c"; mkdir -p "$c"
  printf 'SEL' >"$c/sel"
  printf 'OLD' >"$c/clip"
  printf '%s' "$d" | env STUB_MODE=ok STUB_COPY=fail STUB_CALLS=$c/calls STUB_ARGS=$c/args \
    STUB_ARGV=$c/argv STUB_TASK=$c/task STUB_CLIP=$c/clip STUB_SELECTION=$c/sel \
    PATH="$bin:/usr/bin:/bin" HERDR_BIN="$bin/herdr-app" "$script" 2>"$c/err"
  code=$?
  p5_runs=$((p5_runs + 1))
  id="P5 d=$(json "$d")"
  [ "$code" = 1 ] && [ ! -e "$c/calls" ] || bad "$id" "exit $code, herdr calls: $(cat "$c/calls" 2>/dev/null)"
  grep -q 'could not copy the selection' "$c/err" || bad "$id" "no reason: $(cat "$c/err")"
  want=${d:-OLD}
  [ "$(cat "$c/clip")" = "$want" ] || bad "$id" "clipboard '$(cat "$c/clip")', want '$want'"
done

echo "runs: P1 $p1_runs, P2 $p2_runs, P3 $p3_runs, P4 $p4_runs, P5 $p5_runs"
for id in $KNOWN; do
  if grep -qx "$id" "$work/seen" 2>/dev/null; then echo "FINDING $id (known, see SKILL.md)"
  else echo "FIXED? $id no longer reproduces: remove it from KNOWN and the SKILL.md findings"; fi
done
fails=$(grep -c . "$work/fails" 2>/dev/null || echo 0)
[ "$fails" = 0 ] && echo "ALL PASS" || echo "$fails FAIL"
exit $((fails > 0))
