#!/bin/sh
# Model-checks HudFlow.tla with TLC under both hud settings. Exit 0 only when both pass.
# Usage: check.sh [SPEC.tla]   (default: HudFlow.tla next to this script)
set -u
dir=$(cd "$(dirname "$0")" && pwd)
spec=${1:-$dir/HudFlow.tla}
tool='http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4'
mise install -q java@temurin-25 "$tool" >/dev/null || exit 2
jar=$(mise where "$tool")/tla2tools.jar
java=$(mise which java --tool java@temurin-25)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$spec" "$work/HudFlow.tla"
status=0
for cfg in HudFlow.cfg HudFlowOff.cfg; do
  cp "$dir/$cfg" "$work/$cfg"
  echo "== $cfg"
  (cd "$work" && "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 \
    -config "$cfg" HudFlow.tla) >"$work/out" 2>&1
  if grep -q "No error has been found" "$work/out"; then
    grep -E "distinct states found" "$work/out"
    echo "PASS"
  else
    grep -E "^Error:|is violated|^State [0-9]+:|^/\\\\ |<.*line [0-9]+" "$work/out"
    echo "FAIL"
    status=1
  fi
done
exit $status
