---
name: verify-keypipe-trigger
description: Exhaustively verify keypipe's @@@ firing contract (TriggerMatcher.feed plus the Engine.key reset loop) over every keystroke sequence up to a bound, and track the MVP goal "start in background, type @@@, see a notification". Use after touching Sources/keypipe/Trigger.swift, Engine.key/hotkey in Sources/keypipe/Engine.swift, the --smoke-feed branch in main.swift, trigger limits in Config.swift, or before claiming the @@@ goal works. Also lists the planned formal checks for the extension design (docs/design/extension-architecture.md) so an implementer knows what each PR must make pass.
---

# verify-keypipe-trigger

## Goal this skill tracks

Minimum capability: run `keypipe` once, it keeps running in the background,
and typing `@@@` (the trigger in the JSON config) shows a notification.

| ID | Item | How to check | Status at sync commit |
| --- | --- | --- | --- |
| G1 | The command returns and the daemon keeps running | Start with a trailing `&`; `verify-keypipe-rules` M0b | PASS with `&` (the daemon runs its CFRunLoop in the foreground by design; verify.sh and the manual check both start it with `&`). |
| G2 | The running daemon receives keystrokes | `verify-keypipe-rules/verify.sh` live items M1 and M3 | PASS on a Mac with Accessibility granted (2026-11-01). `MacKeyTap.swift` installs a listen-only CGEventTap and feeds `Engine.key`. |
| G3 | `@@@` fires the rule exactly once per completed `@@@` | `check.sh` (below) | PASS within the bounds below (rerun 2026-11-01 at `b48baf6`). |
| G4 | A match shows a notification | `"output": "notify"` rule, `@@@` typed where no text field is focused | PARTIAL. `notify` is a builtin and its `osascript display notification` exits 0 (measured). The banner itself has not been observed by a person: the 2026-11-01 manual check fired only the `replaceInput` rule. |
| G5 | Physical keystrokes fire the rule (not only `System Events`) | User types `hello@@@` in TextEdit with the daemon running | PASS (2026-11-01). The user typed on the keyboard; `/tmp/keypipe.log` shows 4 fires with `apply replaceInput`. |

Do not mark G1, G2 or G4 PASS until the code changes and the check above is rerun.

## The verified property (G3)

Property: for every keystroke sequence, the `@@@` action runs on the keystroke
that completes three `@` in a row since the last fire, and at no other keystroke.
Harm if broken: the user types `@@@` and nothing happens, or `@@@@` fires twice
(two notifications).

Why this tool: Swift has no code-level verifier in this toolchain, so the check
feeds the real `TriggerMatcher` every input up to a bound and compares against
an independent spec (a run counter, no strings, no `hasSuffix`).

Bounds and assumptions:

- In-process (`Tests/keypipeTests/TriggerExhaustiveTests.swift`): every sequence
  over `@`, `a`, `\n`, `U+0301` (lone combining mark) up to length 8, with
  `maxBuffer` 3, 4 and 64; with and without reset after a hit. Plus every prefix
  length 0..192 before `a@@@` at the default buffer.
- Through the binary (`--smoke-feed`, so the real `Engine.key` loop): every
  sequence over `@`, `a` up to length 7 (254 inputs). The config is one rule
  `{"trigger":"@@@"}` with the default `when` (`focus: any`), so rule selection
  (`Context.swift` `select`/`matches`) always holds and is not what this check
  verifies.
- One rule (`@@@`). Multiple overlapping triggers are not covered. `{@@, @@@}`
  makes `@@@` unreachable, which README documents as the streaming caveat.
- Hotkeys are not covered: `Engine.hotkey` resets the matcher on every chord
  (`Engine.swift:131-135`), so a chord typed between `@@` and `@` breaks the
  run. No sequence in the sweep contains a chord.
- The in-process test mirrors `Engine.key` (`Engine.swift:123-127`). The binary
  pass is what ties the check to the real loop.

## Run it

From the repo root:

```sh
.claude/skills/verify-keypipe-trigger/check.sh
```

It runs `swift test --filter TriggerExhaustiveTests`, builds, then the binary
sweep. About 10 seconds. Exit 0 and a final line `PASS binary: 254 inputs ...`
mean G3 holds. `verify-keypipe` V7b also runs these tests via `swift test`.

## Reading a failure

A failure prints the keys, where it fired, and where the spec says it should:
`maxBuffer 64, keys [U+0301 ... @ @ @ \n]: hit at [6, 7], want [6]` reads "after
the newline it fired a second time without a new @@@".

- Real bug: the change altered `Trigger.swift` or `Engine.key` and the spec in
  the test still describes the intended behavior. Fix the code, not the test.
- Modeling error: the binary sweep passes but the in-process test fails, or the
  reverse. Diff the mirror loop in `actualFires` against `Engine.swift:123-127`.
- Intended change (for example a new reset rule or a multi-rule priority):
  change `expectedFiresWithReset` / `expectedFiresWithoutReset` and
  `expected_hits` in `check.sh` together, show the old check failing on the new
  code first, then update this file.

## Proven able to fail

Each scratch break was caught, then reverted:

| Break | Caught by | When |
| --- | --- | --- |
| Remove `matcher.reset()` in `Engine.key` (was `feedAndRun`) | binary sweep: `@@@@` fired 2 times, want 1 | 2026-11-01 at `b48baf6`, re-proven after the description update |
| Trim by `removeAll()` when `chars.count >= maxBuffer` | prefix test: prefix length 60, final `@@@` did not fire | original |
| `hasSuffix` replaced by `contains` in `feed` | exhaustive test: `... @ @ @ \n` hit at [6, 7], want [6] | original |

## Coverage record

- `Sources/keypipe/Trigger.swift`: `triggerMaxBuffer` (line 6), `TriggerMatcher.init` (70-80), `reset` (84-86), `feed` (89-99).
- `Sources/keypipe/Engine.swift`: `Engine.key` (123-127, the reset loop), `Engine.hotkey` (131-135, resets too; not swept).
- `Sources/keypipe/main.swift`: the `--smoke-feed` branch (96-108) that drives `Engine.key`.
- `Sources/keypipe/Config.swift`: trigger length cap (133-134). The G4 "action type allowlist" no longer exists; the output allowlist is `parseOutput` (84-110) and is covered behaviourally by `verify-keypipe-rules` R2.

Sync commit: `b48baf6`. When any covered file changes after this commit, rerun
`check.sh` and reread the lines above. Move the sync commit forward only after
confirming the spec and line ranges still describe the code at the new commit.

Sync history: `f3299d2` → `b48baf6` (2026-11-01). Between them `feedAndRun`
was folded into `Engine.key` (commit 504917d) and hotkeys were added (c911d62).
The check kept passing across that span because `--smoke-feed` followed the
loop into `Engine.key`; only the description (line ranges, the test comment, the
`contextMatches` stub note) was stale. No property changed.

## Checks for the extension design

These describe what `docs/design/extension-architecture.md` promises. They are
implemented on branch `feat/extension-architecture` and run in `swift test`
(and so in `verify-keypipe` V7b and `verify-keypipe-rules` R1b). Where they live:
P1 `ReportTests`; P2 `EngineTests.testFailedSpawnIsReportedAsFailedNotStarted`;
P3 `EngineTests.testJobParsesTheParentsBytesNotTheFile`; P4
`FactsTests.testLazyReadsOverEveryTermAndOutcome`; P5
`FactsTests.testUnreadableStopsWithoutFallingThrough`; P6
`FactsTests.testGatesNeverReadTheField` and `testTerminalAllowsOnlyFocusAnyHotkeys`;
P7 `FactsTests.testDenyNeedsAppNextToASlowFactAndBlocksWhenUnreadable`; P8
`FactsTests.testGlobsKeepExactIdsExact`; P9
`SinksTests.testValidityIsDerivedFromEverySinkSpec`; P10
`SinksTests.testTypeTextWithoutACaretFailsAsUnsupported`. Proven able to fail
(each break caught, then reverted): no memo in FactSheet (P4), unreadable falls
through (P5), secure gate removed (P6), front-change check removed (R12f),
LineDesktop types text (P10). The original plan follows. Behavioural items (fake-desktop feeds, live items) go to
`verify-keypipe-rules` and `verify-keypipe-terminals` (see their "Planned
items"); this list is the exhaustive / property part.

| ID | PR | Property | Harm if broken | Check shape (bounds) |
| --- | --- | --- | --- | --- |
| P1 | PR1 | `--line` is a projection of `FireResult`: for every `FireResult` case, exit code is 0 iff `isHit` (noInput and failed count as hits, as `main.swift:92-94` today), 2 otherwise, and stdout is the line unchanged. `--report` renders every case to exactly the line in `Tests/keypipeTests/Fixtures/report-v1.jsonl`. | zsh widget replaces the buffer with wrong text, or voice-switch pastes the original on failure | In-process: enumerate all `FireResult` cases (use `CaseIterable` on a mirror enum or a hand list that a test asserts is complete by count); binary: `--line --report` over each case driven by a fake context, diffed byte-for-byte against the fixture |
| P2 | PR1 | A background spawn that fails never reports `started`: the `background` closure's `false` maps to `failed(stage: spawn)`. | voice-switch logs "delivered" for work that never ran | In-process with a stub closure returning false; `--report` shows `"stage":"spawn"` |
| P3 | PR1 | The job child indexes the bytes it was handed, never the file: for two configs A ≠ B, a `JobRequest` built from A with `rule: i` runs A's rule i even when the path now holds B. | config edit makes a background fire run another rule | In-process: write B over the path after building the request from A, run `runJobProcess` logic on the request, assert the rule's shell script is A's |
| P4 | PR2 | Lazy fact reads: for every `when` of up to 3 terms with costs in {structural, cheap, slow} and every assignment of each fact to {matches, differs, unreadable}, a fact is read iff every cheaper term of the same rule matched; at most once per fire; the verdict is `unreadable` iff the first non-matching term in cost order is unreadable. | URL asked on every keystroke in every app; Automation prompt on non-browser apps | In-process exhaustive over the term/assignment space (3^3 × cost orders) with a counting `Desktop` stub; mirrors `Conditions.evaluate` |
| P5 | PR2 | Unreadable stops the fire: with two rules on one trigger where rule 0 has an unreadable fact and rule 1 would match, the result is `unreadable`, nothing is erased, no shell runs. | a GitHub-only transform silently becomes the catch-all rule | Fake-desktop feed asserting no `erase`, no transform exit line, `keypipe unreadable` line |
| P6 | PR2 | Gates run before any field read: for every snapshot in {composing, terminal, secure, deny-match} × {textField, any} × {text trigger, hotkey}, `desktop.text(_:)` is never called when a gate blocks; `terminal` blocks only candidates with `focus: textField` (M18). | keypipe reads a password field; terminal pane leaks into a shell | In-process exhaustive over the product above with a `Desktop` stub that fails the test on `text(_:)` |
| P7 | PR2 | `deny` parse rule: a slow fact in a `deny` entry without an `app` term is rejected at load; with `app` it is accepted; an unreadable fact in `deny` blocks. | browser asked on every fire in a text editor | Config fixtures (3) + one fake feed |
| P8 | PR2 | Glob matching keeps every existing exact-match config meaning: for every bundle id in the test corpus, `anyOf([id]).matches(id)` and no other id in the corpus matches. | a rule starts firing in the wrong app after the glob change | In-process over the ids used in `Tests/` and `config.example.json` |
| P9 | PR3 | Output rules are derived, not listed: for every `Sink` case, `parseOutput` rejects `onFail.output` iff `spec.failures` is empty, rejects it as a background fallback iff `!detachable`, requires `focus: textField` iff `needsTextField`; the error strings equal today's (`ConfigTests`). | a new sink silently escapes the onFail / background rules | In-process over `Sink.allCases` |
| P10 | PR3 | No fake success: `typeText` on a `Desktop` whose `typeText` returns false yields `Failure.unsupported`, and `--line --report` shows `"failure":"unsupported"`. | voice reports delivered while the text went nowhere | Fake feed through `--line` |

Deliberately not planned: a property over the erase/readback polling
(`performErase`, `performWrite`). Decision C leaves that code untouched, and
`verify-keypipe-rules` R4a-f already covers it behaviourally.
