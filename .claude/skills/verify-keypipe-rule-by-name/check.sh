#!/usr/bin/env bash
# Bounded-exhaustive check of `keypipe --rule NAME` (see SKILL.md next to this file).
# Every case runs the real binary; the oracle below is the spec. Exit 0 iff every property passes.
#   P1 command line   every argv up to MAXLEN tokens: refused (exit 2 + usage) exactly when the spec says
#   P2 names          duplicate rule names are a config error (exit 1)
#   P3 selection      --rule X runs the one rule named X, never a rule labelled X; no such name -> exit 2
#   P4 gates          deny and when.app still apply to a rule picked by name
#   P5 input          the rule's KEYPIPE_INPUT is stdin byte for byte, for text/hotkey x textField/any
#   P6 background     a background rule picked by name gets stdin too
# Bounds: MAXLEN (default 3, deep 4) and MAXRULES (default 2, deep 3). DEEP=1 sets both deep.
set -u
cd "$(dirname "$0")/../../.." || exit 1
swift build >/dev/null || { echo "FAIL swift build"; exit 1; }

BIN="$PWD/.build/debug/keypipe"
MAXLEN=${MAXLEN:-3}
MAXRULES=${MAXRULES:-2}
if [ "${DEEP:-0}" = 1 ]; then MAXLEN=4; MAXRULES=3; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export KP_OUT="$WORK/out"
status=0

# ---------------------------------------------------------------- P1 command line
# Spec of the single parse in Sources/keypipe/main.swift, with --rule added.
TAKES=" --rule --line --app --config "
ALONE=" --report --triggers --feed-stdin "
MODES=(--triggers --line --rule --feed-stdin)
spec_refuses() { # args... ; returns 0 when the parse must refuse (exit 2 before the config)
  local -a a=("$@")
  local n=${#a[@]} i=0 seen=" " x
  local line_v="" rule_v="" has_line=0 has_rule=0
  while [ "$i" -lt "$n" ]; do
    x="${a[i]}"
    case "$seen" in *" [$x] "*) return 0 ;; esac # given twice
    if [[ "$TAKES" == *" $x "* && -n "$x" ]]; then
      [ $((i + 1)) -lt "$n" ] || return 0 # needs a value
      seen="$seen[$x] "
      [ "$x" = --line ] && { has_line=1; line_v="${a[i + 1]}"; }
      [ "$x" = --rule ] && { has_rule=1; rule_v="${a[i + 1]}"; }
      i=$((i + 2))
    elif [[ "$ALONE" == *" $x "* && -n "$x" ]]; then
      seen="$seen[$x] "
      i=$((i + 1))
    else
      return 0 # unknown argument
    fi
  done
  for x in --report --app; do # a modifier needs --line or --rule
    case "$seen" in *" [$x] "*) [ $has_line = 1 ] || [ $has_rule = 1 ] || return 0 ;; esac
  done
  [ $has_line = 1 ] && [ -z "$line_v" ] && return 0
  [ $has_rule = 1 ] && [ -z "$rule_v" ] && return 0
  local count=0
  for x in "${MODES[@]}"; do case "$seen" in *" [$x] "*) count=$((count + 1)) ;; esac; done
  [ "$count" -le 1 ] || return 0
  return 1
}

TOKENS=(--rule --line --app --report --triggers --feed-stdin g "")
p1_checked=0
p1_fail=""
for ((len = 0; len <= MAXLEN; len++)); do
  total=1
  for ((k = 0; k < len; k++)); do total=$((total * ${#TOKENS[@]})); done
  for ((n = 0; n < total; n++)); do
    [ -z "$p1_fail" ] || break
    args=()
    m=$n
    for ((k = 0; k < len; k++)); do
      args+=("${TOKENS[m % ${#TOKENS[@]}]}")
      m=$((m / ${#TOKENS[@]}))
    done
    # A config path that does not exist: a refusal must come first (2); anything accepted then
    # fails reading the config (1). So 1 means "the parse let it through".
    full=(--config "$WORK/missing.json" "${args[@]}")
    err="$("$BIN" "${full[@]}" </dev/null 2>&1 >/dev/null)"
    code=$?
    if [ $code = 2 ] && [[ "$err" == *"usage:"* ]]; then got=refuse; else got="exit $code"; fi
    if spec_refuses "${full[@]}"; then want=refuse; else want="exit 1"; fi
    if [ "$got" != "$want" ]; then
      shown=""
      for x in "${full[@]}"; do shown="$shown '${x}'"; done
      p1_fail="argv${shown}: got $got, want $want; stderr: $(printf '%s' "$err" | head -n 1)"
    fi
    p1_checked=$((p1_checked + 1))
  done
done
if [ -n "$p1_fail" ]; then
  echo "FAIL P1 command line: $p1_fail"; status=1
else
  echo "PASS P1 command line: $p1_checked argv up to $MAXLEN tokens over {${TOKENS[*]} ''} match the spec"
fi

# ---------------------------------------------------------------- helpers for P2-P6
# A rule's output appends "R<index>[<KEYPIPE_INPUT>]" to $KP_OUT, so the file says which rules
# ran and with what input.
mark() { printf '"shell": "printf %s \\"$KEYPIPE_INPUT\\" >> \\"$KP_OUT\\""' "'R$1[%s]'"; }
run() { # stdin, args... ; sets code, out, err; $KP_OUT holds what ran
  local input="$1"
  shift
  rm -f "$KP_OUT"
  : >"$KP_OUT"
  printf '%s' "$input" >"$WORK/stdin"
  "$BIN" "$@" <"$WORK/stdin" >"$WORK/stdout" 2>"$WORK/stderr"
  code=$?
  out="$(cat "$WORK/stdout")"
  err="$(cat "$WORK/stderr")"
}
ran() { cat "$KP_OUT"; }

# ---------------------------------------------------------------- P2 + P3 names and selection
# Each rule is one of 8: kind {text @@@, hotkey ctrl+cmd+g} x ident {none, name a, name b, label a}.
rule_json() { # option index
  local o=$1 i=$2 kind ident
  if [ $((o % 2)) = 0 ]; then kind='"trigger": "@@@"'; else kind='"hotkey": "ctrl+cmd+g"'; fi
  case $((o / 2)) in
    0) ident='' ;;
    1) ident='"name": "a", ' ;;
    2) ident='"name": "b", ' ;;
    3) ident='"label": "a", ' ;;
  esac
  printf '{ %s, %s"output": { %s } }' "$kind" "$ident" "$(mark "$i")"
}
name_of() { case $(($1 / 2)) in 1) echo a ;; 2) echo b ;; *) echo - ;; esac; }

p3_checked=0
p3_fail=""
for ((count = 1; count <= MAXRULES; count++)); do
  [ -z "$p3_fail" ] || break
  total=1
  for ((k = 0; k < count; k++)); do total=$((total * 8)); done
  for ((n = 0; n < total; n++)); do
    [ -z "$p3_fail" ] || break
    opts=()
    m=$n
    for ((k = 0; k < count; k++)); do opts+=($((m % 8))); m=$((m / 8)); done
    body=""
    names=()
    for ((k = 0; k < count; k++)); do
      [ -n "$body" ] && body="$body, "
      body="$body$(rule_json "${opts[k]}" "$k")"
      names+=("$(name_of "${opts[k]}")")
    done
    printf '{ "rules": [ %s ] }' "$body" >"$WORK/config.json"
    dup=0
    [ "$count" -ge 2 ] && for ((p = 0; p < count; p++)); do
      for ((q = p + 1; q < count; q++)); do
        [ "${names[p]}" != - ] && [ "${names[p]}" = "${names[q]}" ] && dup=1
      done
    done
    for req in a b c; do
      run "note 1" --config "$WORK/config.json" --rule "$req"
      want_idx=-1
      for ((k = 0; k < count; k++)); do [ "${names[k]}" = "$req" ] && want_idx=$k; done
      why=""
      if [ $dup = 1 ]; then
        { [ $code = 1 ] && [ -z "$(ran)" ]; } || why="P2 duplicate name: got exit $code ran '$(ran)', want exit 1 and nothing run"
      elif [ $want_idx -ge 0 ]; then
        { [ $code = 0 ] && [ "$(ran)" = "R$want_idx[note 1]" ]; } ||
          why="P3 got exit $code ran '$(ran)', want exit 0 and exactly 'R$want_idx[note 1]'"
      else
        { [ $code = 2 ] && [ -z "$(ran)" ] && [[ "$err" != *"unknown argument"* ]]; } ||
          why="P3 no rule named $req: got exit $code ran '$(ran)', want exit 2, nothing run, not an unknown-argument refusal"
      fi
      if [ -n "$why" ]; then
        p3_fail="$why; --rule $req; config $(cat "$WORK/config.json"); stderr: $(printf '%s' "$err" | head -n 1)"
        break
      fi
      p3_checked=$((p3_checked + 1))
    done
    # No such name with --report: still a calling error, no report line.
    if [ -z "$p3_fail" ] && [ $dup = 0 ]; then
      run "note 1" --config "$WORK/config.json" --rule c --report
      if ! { [ $code = 2 ] && [ -z "$out" ] && [ -z "$(ran)" ]; }; then
        p3_fail="P3 --rule c --report with no rule c: got exit $code stdout '$out', want exit 2 and empty stdout; config $(cat "$WORK/config.json")"
      fi
      p3_checked=$((p3_checked + 1))
    fi
  done
done
if [ -n "$p3_fail" ]; then
  echo "FAIL P2/P3 names and selection: $p3_fail"; status=1
else
  echo "PASS P2/P3 names and selection: $p3_checked runs over every config of up to $MAXRULES rules"
fi

# ---------------------------------------------------------------- P4 gates
cat >"$WORK/gates.json" <<EOF
{ "deny": [ { "app": ["com.example.deny"] } ],
  "rules": [
    { "trigger": "@@@", "name": "a", "output": { $(mark 0) } },
    { "hotkey": "ctrl+cmd+g", "name": "b", "when": { "app": ["com.example.only"] }, "output": { $(mark 1) } } ] }
EOF
p4_fail=""
p4() { # want_code, want_ran, want_stdout_substring, args...
  local wc=$1 wr=$2 wo=$3
  shift 3
  run "note 1" --config "$WORK/gates.json" "$@"
  if ! { [ "$code" = "$wc" ] && [ "$(ran)" = "$wr" ] && [[ "$out" == *"$wo"* ]]; }; then
    [ -n "$p4_fail" ] || p4_fail="$*: got exit $code ran '$(ran)' stdout '$out', want exit $wc ran '$wr' stdout containing '$wo'; stderr: $(printf '%s' "$err" | head -n 1)"
  fi
}
p4 2 "" "" --rule a --app com.example.deny
p4 0 "" '"reason":"deny"' --rule a --app com.example.deny --report
p4 2 "" "" --rule b --app com.example.other
p4 0 "" '"outcome":"nomatch"' --rule b --app com.example.other --report
p4 0 "R1[note 1]" "" --rule b --app com.example.only
p4 0 "R1[note 1]" '"outcome":"delivered","rule":1' --rule b --app com.example.only --report
if [ -n "$p4_fail" ]; then
  echo "FAIL P4 gates: $p4_fail"; status=1
else
  echo "PASS P4 gates: deny and when.app apply to --rule (6 cases)"
fi

# ---------------------------------------------------------------- P5 input
p5_fail=""
p5_checked=0
inputs=("" "note 1" 'a"b $(x) `y` \n' "$(printf '日本語\n二行目')")
for kind in '"trigger": "@@@"' '"hotkey": "ctrl+cmd+g"'; do
  for focus in textField any; do
    printf '{ "rules": [ { %s, "name": "a", "when": { "focus": "%s" }, "output": { %s } } ] }' \
      "$kind" "$focus" "$(mark 0)" >"$WORK/input.json"
    for s in "${inputs[@]}"; do
      run "$s" --config "$WORK/input.json" --rule a --app com.example.any
      printf 'R0[%s]' "$s" >"$WORK/want"
      if ! { [ $code = 0 ] && cmp -s "$KP_OUT" "$WORK/want"; }; then
        [ -n "$p5_fail" ] || p5_fail="$kind focus $focus stdin '$s': got exit $code ran '$(ran)', want exit 0 ran 'R0[$s]'; stderr: $(printf '%s' "$err" | head -n 1)"
      fi
      p5_checked=$((p5_checked + 1))
    done
  done
done
if [ -n "$p5_fail" ]; then
  echo "FAIL P5 input: $p5_fail"; status=1
else
  echo "PASS P5 input: KEYPIPE_INPUT is stdin in $p5_checked runs (text/hotkey x textField/any x ${#inputs[@]} inputs)"
fi

# ---------------------------------------------------------------- P6 background
printf '{ "rules": [ { "hotkey": "ctrl+cmd+g", "name": "a", "output": { %s, "background": true } } ] }' \
  "$(mark 0)" >"$WORK/bg.json"
run "note 1" --config "$WORK/bg.json" --rule a --app com.example.any
for ((t = 0; t < 50; t++)); do [ -n "$(ran)" ] && break; sleep 0.1; done
if [ $code = 0 ] && [ "$(ran)" = "R0[note 1]" ]; then
  echo "PASS P6 background: the detached job got stdin"
else
  echo "FAIL P6 background: got exit $code ran '$(ran)' after 5 s, want exit 0 ran 'R0[note 1]'; stderr: $(printf '%s' "$err" | head -n 1)"
  status=1
fi

exit $status
