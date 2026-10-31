---
name: verify-keypipe-trigger
description: Exhaustively verify keypipe's @@@ firing contract (TriggerMatcher.feed plus the feedAndRun reset loop) over every keystroke sequence up to a bound, and track the MVP goal "start in background, type @@@, see a notification". Use after touching Sources/keypipe/Trigger.swift, the feedAndRun loop in Sources/keypipe/main.swift, trigger limits in Config.swift, or before claiming the @@@ goal works.
---

# verify-keypipe-trigger

## Goal this skill tracks

Minimum capability: run `keypipe` once, it keeps running in the background,
and typing `@@@` (the trigger in the JSON config) shows a notification.

| ID | Item | How to check | Status at sync commit |
| --- | --- | --- | --- |
| G1 | The command returns and the daemon keeps running | `perl -e 'alarm 3; exec @ARGV' .build/debug/keypipe --config config.example.json; echo $?` returns before the alarm | FAIL. Exit 142: the command stays in the foreground (`main.swift:76-83`). With a trailing `&` it does stay alive (verify-keypipe V2f). |
| G2 | The running daemon receives keystrokes | `verify-keypipe-rules/verify.sh` live items M1 and M3 | PASS on a Mac with Accessibility granted (2026-11-01). `MacKeyTap.swift` installs a listen-only CGEventTap and feeds `Engine.key`. |
| G3 | `@@@` fires the rule exactly once per completed `@@@` | `check.sh` (below) | PASS within the bounds below. |
| G4 | A match shows a notification | `--smoke-feed '@@@'` with a notification config | PARTIAL. `"type": "notify"` is rejected by `loadConfig` (`Config.swift:75-84`, `unknown action type: notify`). A `shell` action running `osascript -e 'display notification ...'` matches and exits 0. That the banner appears was not observed by the check. |

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
- Through the binary (`--smoke-feed`, so the real `feedAndRun` in `main.swift`):
  every sequence over `@`, `a` up to length 7 (254 inputs).
- One rule (`@@@`). Multiple overlapping triggers are not covered. `{@@, @@@}`
  makes `@@@` unreachable, which README documents as the streaming caveat.
- `contextMatches` is a stub that returns true, so context is not covered.
- The in-process test mirrors `feedAndRun` (`main.swift:29-43`). The binary pass
  is what ties the check to the real loop.

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

- Real bug: the change altered `Trigger.swift` or `feedAndRun` and the spec in
  the test still describes the intended behavior. Fix the code, not the test.
- Modeling error: the binary sweep passes but the in-process test fails, or the
  reverse. Diff the mirror loop in `actualFires` against `main.swift:29-43`.
- Intended change (for example a new reset rule or a multi-rule priority):
  change `expectedFiresWithReset` / `expectedFiresWithoutReset` and
  `expected_hits` in `check.sh` together, show the old check failing on the new
  code first, then update this file.

## Proven able to fail

Each scratch break was caught, then reverted:

| Break | Caught by |
| --- | --- |
| Remove `matcher.reset()` in `feedAndRun` | binary sweep: `@@@@` fired 2 times, want 1 |
| Trim by `removeAll()` when `chars.count >= maxBuffer` | prefix test: prefix length 60, final `@@@` did not fire |
| `hasSuffix` replaced by `contains` in `feed` | exhaustive test: `... @ @ @ \n` hit at [6, 7], want [6] |

## Coverage record

- `Sources/keypipe/Trigger.swift`: `TriggerMatcher.init`, `feed`, `reset`, `triggerMaxBuffer` (lines 21-66).
- `Sources/keypipe/main.swift`: `feedAndRun` (lines 27-43) and the `--smoke-feed` branch (lines 60-65).
- `Sources/keypipe/Config.swift`: trigger length cap (lines 70-74), action type allowlist (lines 75-84) for G4.

Sync commit: `f3299d2`. When any covered file changes after this commit, rerun
`check.sh` and reread the lines above. Move the sync commit forward only after
confirming the spec and line ranges still describe the code at the new commit.
