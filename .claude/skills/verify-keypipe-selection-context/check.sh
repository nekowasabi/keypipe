#!/bin/sh
# Model-checks docs/design/statechart/SelectionCapture.tla with TLC.
#   after:   every invariant holds (the planned design).
#   before:  each invariant alone, against the expected verdict for today's script.
#   mutants: two broken variants of the planned design must each break their invariant.
# Exit 0 only when every verdict matches.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$dir/../../.." && pwd)
spec=$repo/docs/design/statechart/SelectionCapture.tla
tool='http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4'
mise install -q java@temurin-25 "$tool" >/dev/null || exit 2
jar=$(mise where "$tool")/tla2tools.jar
java=$(mise which java --tool java@temurin-25)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

# tlc NAME AFTER INVARIANT... -> prints PASS or the violated invariant
tlc() {
  name=$1 after=$2
  shift 2
  { echo "SPECIFICATION Spec"; echo "CONSTANT After = $after"
    for inv in "$@"; do echo "INVARIANT $inv"; done; } >"$work/$name.cfg"
  (cd "$work" && "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 1 \
    -config "$name.cfg" SelectionCapture.tla) >"$work/$name.out" 2>&1
  if grep -q "No error has been found" "$work/$name.out"; then echo PASS
  else sed -n 's/^Error: Invariant \([A-Za-z]*\) is violated.*/\1/p' "$work/$name.out"; fi
}
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1: $2"
  else echo "FAIL $1: expected $3, got ${2:-<TLC error, see below>}"; cat "$work/$4.out"; status=1; fi
}

all="HrefNeverDropped BrowserUrlAttached PageUrlOnlyFromBrowser OldClipboardRestored FailedCopyNotSent"
cp "$spec" "$work/SelectionCapture.tla"
# shellcheck disable=SC2086
expect "after (all)" "$(tlc after TRUE $all)" PASS after

for pair in HrefNeverDropped:HrefNeverDropped BrowserUrlAttached:BrowserUrlAttached \
  OldClipboardRestored:OldClipboardRestored PageUrlOnlyFromBrowser:PASS FailedCopyNotSent:PASS; do
  inv=${pair%%:*} want=${pair#*:}
  expect "before $inv" "$(tlc "b-$inv" FALSE "$inv")" "$want" "b-$inv"
done

# M1: attach the source-url for any app (Slack's app shell would pass as "the page").
sed 's/front \\notin Browsers -> "none"/FALSE -> "none"/' "$spec" >"$work/SelectionCapture.tla"
expect "mutant M1" "$(tlc m1 TRUE PageUrlOnlyFromBrowser)" PageUrlOnlyFromBrowser m1
# M2: no tab-URL fallback when the browser left no source-url (Safari).
sed 's/t = "value"           -> "tab"/t = "value"           -> "none"/' "$spec" >"$work/SelectionCapture.tla"
expect "mutant M2" "$(tlc m2 TRUE BrowserUrlAttached)" BrowserUrlAttached m2

# M3: no Accessibility read when the copy has no HTML (Slack in Chrome loses the link).
sed 's/hrefKept'"'"' = (hasLink \/\\ (pbHtml \\\/ axAvail))/hrefKept'"'"' = (hasLink \/\\ pbHtml)/' "$spec" >"$work/SelectionCapture.tla"
expect "mutant M3" "$(tlc m3 TRUE HrefNeverDropped)" HrefNeverDropped m3

[ "$status" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $status
