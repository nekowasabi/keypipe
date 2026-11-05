---
name: verify-keypipe-windows-core
description: Gate the C# Keypipe.Core fake-desktop fire path on Linux via dotnet test (V1-V12 mapped to C# test names). Use after touching src/Keypipe.Core or tests/Keypipe.Core.Tests, or before claiming the Windows port preserves the fire contract. Does not run TLC and needs no hooks, UIA, or live Notepad.
---

# verify-keypipe-windows-core

`dotnet test` gate for slice 1 of the Windows port (SPEC `keypipe-mvp/plan/2026-11-05/SPEC-windows-core.md`):
the fire procedure ported into C# `Keypipe.Core`, reproduced on a fake desktop. No hooks, no UIA,
no `SendInput`, no live Notepad. `Keypipe.Windows` stays a stub or absent until a later slice.

The contract it gates is fixed by `.claude/skills/verify-keypipe-fire-path/` (V1–V12 below) and
`artifacts/windows-port-analysis.md` §7. The TLA specs under `verify-keypipe-fire-path` stay
authoritative for the model and must remain green if invoked — but this skill never runs TLC;
C# green does not require TLC. Formal follow-up is a later `maintain-formal-verification` slice.

## Fire order (must match, SPEC §Fire order)

1. `TriggerMatcher.feed` 2. terminal filter 3. IME composing (before deny) 4. secure/password
5. deny 6. candidate rules 7. front re-check after slow read 8. erase/read (`runAfterBusy`)
9. background decision 10. `runTransform` 11. `apply`.

Composing and secure stop before deny, erase, and any shell. An unreadable fact stops the fire
and never falls through to the next rule. A trigger whose `when` fails never substitutes a
shorter trigger.

## Verification items V1–V12 → C# tests

`dotnet test` filters use xunit `FullyQualifiedName~<TestName>`. Class names are prescribed:
fire/rule tests in `FireTests`, matcher tests in `TriggerMatcherTests`, sink edge tests in
`SinksTests`, all under `tests/Keypipe.Core.Tests/`.

| ID | Rule (harm when broken) | C# test (class.method) | `dotnet test` filter | Swift reference |
| --- | --- | --- | --- | --- |
| V1 | Composing stops before deny/erase/shell (conversion in progress deleted or sent to a command) | `FireTests.ComposingDoesNotFireOrErase` | `FullyQualifiedName~ComposingDoesNotFireOrErase` | `testComposingDoesNotFireOrErase` |
| V2 | Secure/password field stops the same way (password erased or handed to a shell) | `FireTests.SecureFieldStopsBeforeDenyEraseAndShell` | `FullyQualifiedName~SecureFieldStops` | `HudTests` secure cases / `FactsTests` secure snapshot |
| V3 | Typed trigger in a terminal does nothing; only a hotkey that reads no field passes (whole pane read or erased) | `FireTests.TerminalTextTriggerStops_TerminalHotkeyWithoutFieldPasses` | `FullyQualifiedName~TerminalTextTriggerStops` | `testTerminalFocusDoesNothingAtAll` |
| V4 | Unreadable fact stops, never falls through to the next rule (rule meant for one site runs elsewhere) | `FireTests.UnreadableFactStopsWithoutFallingThrough` | `FullyQualifiedName~UnreadableFactStops` | `testUnreadableStopsWithoutFallingThrough` |
| V5 | Front changed during a slow read erases and runs nothing (backspaces land in the window just switched to) | `FireTests.FrontChangeDuringSlowReadErasesNothing` | `FullyQualifiedName~FrontChangeDuringSlowRead` | `testFrontChangeDuringSlowReadErasesNothing` |
| V6 | This trigger's `when` failing never selects a shorter trigger (`@@@` failing its `when` still fires `@@`) | `FireTests.NoMatchDoesNotEraseOrTryShorterTrigger` | `FullyQualifiedName~NoMatchDoesNotErase` | `testNoMatchDoesNotEraseOrTryShorterTrigger` |
| V7 | Hotkey posts no Backspace; `textField` sees the field (trigger removed), `any` sees empty (chord deletes chars; transform sees trigger or empty) | `FireTests.HotkeyReadsFieldWithoutErasing_AndIgnoresUnconfiguredChords`, `FireTests.AnySuppliesEmptyInputAndErasesOnlyInTextFields` | `FullyQualifiedName~HotkeyReadsField`, `FullyQualifiedName~AnySuppliesEmptyInput` | `testHotkeyReadsFieldWithoutErasingAndIgnoresUnconfiguredChords`, `testAnySuppliesEmptyInputAndErasesOnlyInTextFields` |
| V8 | `--line`/`--rule` (supplied path) pass stdin through for either focus (voice/zsh text dropped, or field sent instead) | `FireTests.FireRuleRunsOnlyThatRuleWithCallersInputInEveryFocus` | `FullyQualifiedName~FireRuleRunsOnlyThatRule` | `testFireRuleRunsOnlyThatRuleWithTheCallersInputInEveryFocus` |
| V9 | Failed transform (nonzero, timeout, empty) delivers nothing; each `onFail` stage runs at most once (empty/failed output wipes the field; fallback loops) | `FireTests.EmptyTransformOutputNotifiesInsteadOfWipingField`, `FireTests.TransformFallbackRunsOnceWithSameInput`, `FireTests.OutputFallbackRunsOnce` | `FullyQualifiedName~EmptyTransformOutput`, `FullyQualifiedName~TransformFallbackRunsOnce`, `FullyQualifiedName~OutputFallbackRunsOnce` | `testEmptyTransformOutputNotifiesInsteadOfWipingField`, `testTransformFallbackRunsOnceWithSameInputAndFailureReason`, `testFallbackFailureNotifiesWithoutRetrying`, `testOutputFallbackReceivesResultAndReason` |
| V10 | `started` is only a background spawn that did start; `typeText` on the supplied path never reports success (phantom delivery recorded; caller believes text was typed with no caret) | `FireTests.FailedSpawnIsReportedAsFailedNotStarted`, `SinksTests.TypeTextOnSuppliedPathIsUnsupported` | `FullyQualifiedName~FailedSpawnIsReported`, `FullyQualifiedName~TypeTextOnSuppliedPath` | `testFailedSpawnIsReportedAsFailedNotStarted`, `testTypeTextWithoutACaretFailsAsUnsupported` |
| V11 | One keystroke returns the longest configured suffix; the firing keystroke clears the buffer (`ab`+`b` fires `b`; with `@@`+`@@@` the 2nd char fires `@@` and `@@@` never accumulates) | `TriggerMatcherTests.LongestMatchWins_AndBufferResetsOnFire` | `FullyQualifiedName~LongestMatchWins` | `testLongestMatchWinsInEitherOrder`, `testDetectsCompletionAndResets` |
| V12 | Erase readback never hands a half-deleted trigger to the transform; within 5 reads of a 3-char trigger, one-backspace-per-read and ignores-backspace apps both yield the body | `FireTests.EraseWaitsForEveryBackspaceBeforeReading` | `FullyQualifiedName~EraseWaitsForEveryBackspace` | `testEraseWaitsForEveryBackspaceBeforeReading`, `testBackspaceAndRewriteRemoveOnlyOneTrigger`, `testEraseWaitsForTheTriggerToLandBeforeBackspacing` |

Full gate: `dotnet test` green for `Keypipe.Core.Tests` covering all of V1–V12. Single-item run:
`dotnet test Keypipe.sln --filter "FullyQualifiedName~<TestName>"`.

## How to run

```sh
sh .claude/skills/verify-keypipe-windows-core/verify.sh
sh .claude/skills/verify-keypipe-windows-core/verify.sh --filter "FullyQualifiedName~LongestMatchWins"
```

Full PR gate (docs + C#; CI `make check` runs the docs half on macos-latest):

```sh
sh .claude/skills/verify-keypipe-windows-core/check.sh
```

`verify.sh` requires `dotnet` on `PATH` (`$HOME/.dotnet` is added inside the script, so no manual
`export PATH` is needed) and FAILs clearly when `Keypipe.sln` is absent. It never runs TLC; to
re-confirm the model separately: `sh .claude/skills/verify-keypipe-fire-path/check.sh`
(TLC 1.7.4; expected FireGates 83 / FireStages 439 / EraseReadback 10 / TriggerMatch 345 states).

## Docs gate (CI check-docs)

CI (`.github/workflows/check.yml`) runs `make check`, whose `check-docs` step runs
`scripts/check-doc-symbols.sh`. That script fails when this `SKILL.md` names backtick
symbols missing from Swift `Sources/`/`Tests/` — which is exactly how PR #11 went red
(C# names like `Keypipe.Core`, `FireTests.*`, `Keypipe.sln`, and the intentionally absent
`SendInput` / `Keypipe.Windows`).

- Run it: `bash scripts/check-doc-symbols.sh` (exit 0 required), or the combined gate
  `sh .claude/skills/verify-keypipe-windows-core/check.sh` (docs first, then `verify.sh`).
- Drive details and suppression rules (`docsym-ok` must sit on the SAME line) live in
  `features/check-docs.md`.
- This skill never deletes Windows coverage to satisfy docs: C# symbols resolve via the
  script's `.cs` index, repo-root files resolve when present, deferred names use a marked
  `docsym-ok` line. Swift-only strictness is unchanged.

## Launch

No daemon, no GUI, no device. Launch = restore + build once via the .NET SDK:

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet --version   # 8.0.x
dotnet test Keypipe.sln
```

`src/Keypipe.Core/` targets `net8.0`; `tests/Keypipe.Core.Tests/` is xunit (or NUnit — the skill
pins whichever the solution uses; filters above work for either). Ready means the test host runs,
not just restore: a restore-only pass is not green. There is no server to keep alive and no seed
data; each drive is one `dotnet test` invocation in its own process.

## Doctor

Read-only pre-check when anything looks off:

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet --version              # expect 8.0.x
test -f Keypipe.sln && echo solution-present || echo solution-MISSING
dotnet sln Keypipe.sln list   # must include src/Keypipe.Core + tests/Keypipe.Core.Tests
```

If `dotnet` is missing, install the .NET 8 SDK and re-run — do not hand-simulate results.
If the solution lists projects outside `src/Keypipe.Core`, `tests/Keypipe.Core.Tests`, or an
empty `Keypipe.Windows` stub, that is scope drift for this slice: flag it, do not extend the gate.

## Drive

The harness is xunit (or NUnit) + a C# fake desktop implementing the Core `IDesktop` interface —
a port of `Sources/keypipe/FakeDesktop.swift`, not a new design. Prescribed fake-desktop
capabilities are listed in `features/fake-desktop.md` (JSON context keys, backspace/write timing
modes, focus lattice). Drive one mapped feature per run:

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet test Keypipe.sln --filter "FullyQualifiedName~ComposingDoesNotFireOrErase"
```

Prefer the `FullyQualifiedName~` filters in the V1–V12 table over `--filter ClassName` (class-only
filters hide missing-method regressions: a renamed test still passes the class filter by running
fewer tests). After any single-item run, finish with the full unfiltered gate before claiming green.

## Evidence

What to capture for a proof and where it goes:

- Run the full gate unfiltered: `sh .claude/skills/verify-keypipe-windows-core/verify.sh`.
- Save the transcript: `.verify-evidence/windows-core-<yyyymmdd-hhmmss>/verify.log` (script does
  this when passed a directory, otherwise prints to stdout; full `dotnet test` output counts).
- Proof standard: the real `dotnet test` path against the fake desktop, not hand-rolled drivers or
  test-only shims; capture the command plus the pass/fail summary, not just the last line; the
  per-V table above is the checklist — one passing class filter is incomplete when the map lists
  twelve items. Mocks only where the production boundary already isolates the system (`IDesktop`,
  shell runner); no live hooks/UIA/`SendInput`/Notepad in this slice (MAC/Windows live unverified).
- A run that fails because `Keypipe.sln` is absent is evidence of absence, not of green: the
  script exits nonzero with `FAIL: Keypipe.sln missing` and that is the expected transcript until
  the port lands.

## Cleanup

Nothing to tear down: `dotnet test` leaves no daemon, port, or profile behind. Never kill by
process name. Cleanup removes scratch state only (`bin/`, `obj/`, stray evidence dirs from failed
iterations) — never the proof transcript named above. After cleanup, confirm the evidence file
still exists at the named location.

## Helpers

- `verify.sh` — the C# gate. Executable; invocation is shown under How to run. It adds
  `$HOME/.dotnet` to `PATH` itself, errors clearly when `dotnet` or `Keypipe.sln` is missing,
  forwards extra args to `dotnet test`, and never invokes TLC/mutants.
- `check.sh` — the PR gate (docs + C#). Runs `bash scripts/check-doc-symbols.sh` first
  (short-circuits on docs failure, mirroring CI `make check`), then `verify.sh` with any
  extra args forwarded. Exit 0 only when both pass.
- `features/` — the feature map (index + one file per slice capability). Proof drives one entry
  point per run; the map lists the rest so later runs cover them.
