#!/usr/bin/env bash
# Exhaustive @@@ firing check: in-process (TriggerExhaustiveTests) and through
# the real binary's feedAndRun loop (--smoke-feed). Exit 0 iff both agree with the spec.
set -u
cd "$(dirname "$0")/../../.." || exit 1

swift test --filter TriggerExhaustiveTests || { echo "FAIL in-process exhaustive check"; exit 1; }
swift build >/dev/null || { echo "FAIL swift build"; exit 1; }

BIN=.build/debug/keypipe
CFG="$(mktemp)"
trap 'rm -f "$CFG"' EXIT
printf '{"rules":[{"trigger":"@@@"}]}' > "$CFG"

expected_hits() {
  local s="$1" run=0 hits=0 i
  for ((i = 0; i < ${#s}; i++)); do
    if [ "${s:i:1}" = "@" ]; then
      run=$((run + 1))
      if [ "$run" -eq 3 ]; then hits=$((hits + 1)); run=0; fi
    else
      run=0
    fi
  done
  echo "$hits"
}

MAXLEN=7
checked=0
for ((len = 1; len <= MAXLEN; len++)); do
  for ((n = 0; n < (1 << len); n++)); do
    s=""
    for ((b = 0; b < len; b++)); do
      if (((n >> b) & 1)); then s="$s@"; else s="${s}a"; fi
    done
    out="$("$BIN" --config "$CFG" --smoke-feed "$s" 2>&1)"
    got="$(printf '%s\n' "$out" | sed -n 's/^keypipe smoke-feed hits //p')"
    want="$(expected_hits "$s")"
    if [ "$got" != "$want" ]; then
      echo "FAIL binary: keys '$s' fired $got time(s), want $want"
      printf '%s\n' "$out"
      exit 1
    fi
    checked=$((checked + 1))
  done
done
echo "PASS binary: $checked inputs over {@,a} up to length $MAXLEN match the spec"
