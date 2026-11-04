#!/bin/sh
# Model-checks the four fire-path specs. Exit 0 only when every invariant holds.
# One spec argument checks that file against the config of the same name
# (mutants.sh passes a mutated copy).
set -u
dir=$(cd "$(dirname "$0")" && pwd)
jar=${TLA2TOOLS:-}
java=${JAVA:-java}
if [ -z "$jar" ]; then
  tool='http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4'
  if command -v mise >/dev/null 2>&1; then
    mise install -q java@temurin-25 "$tool" >/dev/null || exit 2
    jar=$(mise where "$tool")/tla2tools.jar
    java=$(mise which java --tool java@temurin-25)
  else
    cache=${XDG_CACHE_HOME:-$HOME/.cache}/keypipe-tlc
    mkdir -p "$cache"
    jar=$cache/tla2tools-1.7.4.jar
    if [ ! -f "$jar" ]; then
      curl -fsSL -o "$jar" https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar || exit 2
    fi
    echo "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  $jar" | sha256sum -c - || exit 2
    java=${JAVA:-java}
  fi
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
if [ $# -ge 1 ]; then
  specs=$1
else
  specs="FireGates.tla FireStages.tla EraseReadback.tla TriggerMatch.tla"
fi
for spec in $specs; do
  base=$(basename "$spec" .tla)
  cp "$spec" "$work/$base.tla"
  cfg=$base.cfg
  if [ $# -ge 2 ]; then cfg=$(basename "$2"); cp "$2" "$work/$cfg"; else cp "$dir/$base.cfg" "$work/$base.cfg"; fi
  echo "== $base"
  (cd "$work" && "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 \
    -config "$cfg" "$base.tla") >"$work/out" 2>&1
  if grep -q "No error has been found" "$work/out"; then
    grep -E "distinct states found" "$work/out"
    echo "PASS"
  else
    grep -E "^Error:|is violated|^State [0-9]+:|^/\\\\ |<.*line [0-9]+" "$work/out" | head -40
    echo "FAIL"
    status=1
  fi
done
exit $status
