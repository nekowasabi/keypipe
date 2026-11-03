#!/bin/sh
# Shows that every rule in HudFlow.tla can fail: each mutant is a code break written as a
# model edit, and check.sh must FAIL on the rule named next to it. Exit 0 only when all do.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
mutant() { # name, expected rule, perl substitution
  perl -0pe "$3" "$dir/HudFlow.tla" >"$work/HudFlow.tla"
  if cmp -s "$dir/HudFlow.tla" "$work/HudFlow.tla"; then
    echo "MUTANT $1: substitution matched nothing"; status=1; return
  fi
  out=$(sh "$dir/check.sh" "$work/HudFlow.tla" 2>&1)
  if printf '%s\n' "$out" | grep -q "Invariant $2 is violated"; then
    echo "MUTANT $1: caught by $2"
  else
    echo "MUTANT $1: NOT caught (expected $2)"; printf '%s\n' "$out"; status=1
  fi
}
# Engine.fire goes back to `defer { desktop.hideBusy() }`: the pill is posted before the hide.
mutant defer-hide SpinnerGoneBeforeItsPill \
  's/pc = "hidden" \/\\ pc\x27 = "idle"/pc = "ran" \/\\ pc\x27 = "pilled"/; s/pc = "ran" \/\\ pc\x27 = "hidden"/pc = "pilled" \/\\ pc\x27 = "idle"/'
# FiredHUD.show drops `hideWork?.cancel()`: the old timer hides the new pill early.
mutant no-cancel NoStaleHide 's/cancelled\x27 = cancelled \\cup pending/cancelled\x27 = cancelled/'
# runAfterBusy's noInput return skips desktop.hideBusy (a return before the hide).
mutant noinput-skips-hide SpinnerGoneAtRest \
  's/pc = "running" \/\\ pc\x27 = "ran"/pc = "running" \/\\ pc\x27 = IF o = "noInput" THEN "idle" ELSE "ran"/'
# showFiredIfNeeded stops excluding noInput.
mutant pill-on-noinput OnePillPerFinishedFire 's/result\[fire\] \\in PillOutcomes/result[fire] \/= "none"/'
# A gate (such as front-changed) moves after desktop.showBusy.
mutant gate-after-spinner GatedFireShowsNothing \
  's/GateStops ==\n  \/\\ pc = "gating"/GateStops ==\n  \/\\ pc \\in {"gating", "running"}/'
# FiredHUD's hide work item stops ordering the panel out.
mutant timer-keeps-pill PillGoneAtRest 's/ELSE \/\\ pill\x27 = 0/ELSE \/\\ pill\x27 = pill/'
exit $status
