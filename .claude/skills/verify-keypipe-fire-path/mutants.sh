#!/bin/sh
# Each mutant is one broken line of the real fire, written as a model edit.
# check.sh must FAIL, and the invariant named here must be the one TLC reports.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
mutant() { # spec, name, expected invariant, perl
  base=$(basename "$1" .tla)
  perl -0pe "$4" "$dir/$1" >"$work/$base.tla"
  if cmp -s "$dir/$1" "$work/$base.tla"; then
    echo "MUTANT $2: substitution matched nothing"; status=1; return
  fi
  out=$(sh "$dir/check.sh" "$work/$base.tla" 2>&1)
  if printf '%s\n' "$out" | grep -q "Invariant $3 is violated"; then
    echo "MUTANT $2: caught by $3"
  else
    echo "MUTANT $2: NOT caught (expected $3)"; printf '%s\n' "$out"; status=1
  fi
}

# Engine.fire: the composing guard is gone, so a conversion in progress continues.
mutant FireGates.tla drop-composing-guard ComposingStops \
  's/\/\\ focus # "composing"\n//'
# Engine.fire: the password guard is gone.
mutant FireGates.tla drop-secure-guard SecureStops \
  's/\/\\ ~secure\n//'
# A text trigger in a terminal is treated like any other app.
mutant FireGates.tla terminal-text-continues TerminalTextStops \
  's/\/\\ focus # "terminal"\n//'
# An unreadable when.url continues as a normal match instead of stopping.
mutant FireGates.tla unreadable-falls-through UnreadableNeverFallsThrough \
  's/sawUnreadable'"'"' = TRUE\n  \/\\ phase'"'"' = "done"\n  \/\\ result'"'"' = "unreadable"\n  \/\\ reason'"'"' = "when"/sawUnreadable'"'"' = TRUE\n  \/\\ phase'"'"' = "ready"\n  \/\\ result'"'"' = "none"\n  \/\\ reason'"'"' = ""/'
# The front changed during the URL read, and the fire erases anyway.
mutant FireGates.tla front-changed-erases FrontChangedDoesNotErase \
  's/reason'"'"' = "front-changed"\n  \/\\ erased'"'"' = FALSE/reason'"'"' = "front-changed"\n  \/\\ erased'"'"' = TRUE/'
# when fails for @@@, so the fire selects @@ instead.
mutant FireGates.tla shorter-fallback NeverShorter \
  's#\\/ FrontMoved \\/ FrontStable#\\/ FrontMoved \\/ FrontStable\n  \\/ SelectShorter#'

# A hotkey posts Backspace.
mutant FireStages.tla hotkey-backspaces HotkeyNeverBackspaces \
  's#erased'"'"' = FALSE \\\* hotkey-field#erased'"'"' = TRUE#; s#erased'"'"' = FALSE \\\* hotkey-any#erased'"'"' = TRUE#'
# focus any in a text field feeds the field to the shell.
mutant FireStages.tla any-feeds-field KeyAnySeesEmpty \
  's#THEN "empty" ELSE "supplied" \\\* any-in-text#THEN "field" ELSE "supplied"#'
# A failed transform still delivers.
mutant FireStages.tla transform-fail-delivers FailedTransformDoesNotDeliver \
  's#delivered'"'"' = FALSE \\\* primary-fail#delivered'"'"' = TRUE#'
# onFail.transform runs a second time.
mutant FireStages.tla second-transform-fallback TransformFallbackOnce \
  's#\\/ FallbackOk \\/ FallbackFail#\\/ FallbackOk \\/ FallbackFail\n  \\/ SecondFallback#'
# onFail.output runs a second time.
mutant FireStages.tla second-output-fallback OutputFallbackOnce \
  's#\\/ OutFbOk \\/ OutFbFail#\\/ OutFbOk \\/ OutFbFail\n  \\/ SecondOutputFallback#'
# --line typeText reports success.
mutant FireStages.tla linetext-succeeds NoFakeTypeText \
  's/\/\\ path = "key"\n  \/\\ focus \\in \{"text", "terminal"\}/\/\\ focus \\in {"text", "terminal"}/'
# A spawn that did not start is reported as started.
mutant FireStages.tla spawn-fail-says-started StartedMeansSpawned \
  's/result'"'"' = "failed"\n  \/\\ failStage'"'"' = "spawn"/result'"'"' = "started"\n  \/\\ failStage'"'"' = "spawn"/'

# performErase returns on the first change, while Backspaces are still in flight.
mutant EraseReadback.tla return-on-first-change NoEarlyPartial \
  's/IF text2 = "body"\n             THEN \/\\ phase'"'"' = "done" \/\\ handed'"'"' = "body"/IF text2 = "body" \\\/ text2 = "partial"\n             THEN \/\\ phase'"'"' = "done" \/\\ handed'"'"' = text2/'
# The hit leaves the trigger in the buffer.
mutant TriggerMatch.tla no-reset ResetOnFire \
  's#buf'"'"' = ""\s+\\\* Engine.key resets after a hit#buf'"'"' = buf2#'
# The shortest suffix wins.
mutant TriggerMatch.tla shortest-wins FiredIsLongest \
  's/Len\(u\) <= Len\(t\)/Len(u) >= Len(t)/'

exit $status
