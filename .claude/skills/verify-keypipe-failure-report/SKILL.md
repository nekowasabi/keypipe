---
name: verify-keypipe-failure-report
description: Bounded-exhaustive check that a send from voice-switch or a hotkey never loses the prompt and always tells the user why it failed. Runs the real keypipe background job over every transform x output x onFail.output outcome (exit with or without stderr, multi-line, over 200 characters, timeout); the real shell/herdr-claude.sh and shell/selection-prompt.sh over every dictation x selection x clipboard x herdr-app result x VOICE_SWITCH_APP; both joined through `keypipe --rule herdr-claude`; two sends racing for the clipboard; and a Cmd+C that fails. Use after touching Failure, ShellStage, shellStage or the notify calls in run(...) in Sources/keypipe/Engine.swift, runShell's stderr in Sources/keypipe/Shell.swift, runJobProcess in Sources/keypipe/Job.swift, shell/herdr-claude.sh or shell/selection-prompt.sh; or before claiming a failed send reaches the user with its reason.
---

# verify-keypipe-failure-report

voice-switch and the hotkey hand the prompt to a background job. Nobody watches a job, so when a
send fails the user has only the notification, and the prompt only if something kept it. This
skill checks both promises over every case inside the bounds below, against the real code.

## Properties

| ID | Property (one sentence) | Harm when broken |
|----|-------------------------|------------------|
| P1 | A background fire that fails gives exactly one notification, `<label, else name, else trigger> <stage> failed: <token>[: <last nonempty stderr line, trimmed, first 200 characters>]`, writes `keypipe [fallback ]<stage> stderr <json>` with the whole line to jobs.log, and hands onFail.output `KEYPIPE_FAILURE` = the bare token (`exit N` or `timeout`); a fire that does not fail notifies nothing. | The user sees `exit 1` and cannot tell a Herdr failure from an empty selection, or a fallback script keyed on `exit 1` stops matching. |
| P2 | `shell/herdr-claude.sh` either calls `herdr-app do tab.new` once with one JSON object whose `argv` is `["claude","--"]` and whose `task` is the prompt byte for byte, and exits 0; or exits 1 with the whole prompt on the clipboard and one stderr line `herdr-claude: prompt copied to the clipboard; tab.new failed...`; or, with nothing said or selected, exits 3 without calling herdr-app. `open -b $VOICE_SWITCH_APP` comes first when it is set, and the old clipboard comes back byte for byte (trailing newlines too) on success and on exit 3. | The dictated instruction and the selection are lost, or go to Claude Code mangled. |
| P3 | Through `keypipe --rule herdr-claude` (no login PATH), a Herdr failure ends as a notification that starts its reason with `herdr-claude: prompt copied to the clipboard; tab.new failed`, with the prompt on the clipboard. | The two halves each pass but the user still sees nothing useful. |
| P4 | Two sends 0.05 to 0.6 s apart each carry their own dictation and the selection, and the old clipboard comes back. | A double press sends the user's clipboard instead of the selection, or loses the clipboard. |
| P5 | When the Cmd+C fails, the send stops with exit 1 and the reason `could not copy the selection`, without calling herdr-app; the dictation, if any, is left on the clipboard, else the old clipboard stays. | Without Accessibility, the dictation goes out alone as if nothing had been selected. |

The prompt is dictation, a blank line, then the selection, or whichever is not empty. Both are
taken after `$(cat)` and `$(pbpaste)`, which drop trailing newlines; that is the intended shape.

## How to run

```sh
bash .claude/skills/verify-keypipe-failure-report/check.sh   # about 2 minutes, exit 0 = every property holds
```

It runs `swift build`, then `.build/debug/keypipe`. No Mac permission, Herdr or clipboard is
touched: jobs run with `PATH=/nonexistent` (so no `osascript` notification reaches the screen;
the `keypipe apply notify` line in jobs.log is the observable), and herdr-app, `pbcopy`,
`pbpaste`, `osascript`, `open` and `sleep` are stubs on the script's `PATH`. The scripts' JSON
encoding and the stub's decoding run the real `/usr/bin/osascript -l JavaScript`. Works with
macOS's `/bin/bash` 3.2.

Output: `runs: P1 33, P2 240, P3 3, P4 6, P5 2`, then `ALL PASS` or `<n> FAIL`. Each `FAIL`
line names the case (`P1 t=... o=... f=...`, `P2 d=... s=... old=... herdr=... app=...`,
`P4 gap=...`, `P5 d=...`) and what differed.

## Bounds

- P1: transform none / ok / fail-with-reason; output.shell (background) exit 0, exit with a
  reason among other stderr lines, exit with no stderr, reason followed by blank lines, a
  300-character reason, timeout (`shellTimeout: 1`); onFail.output none / ok / fail-with-reason.
  33 combinations (a failed transform skips the output; a passing output skips onFail).
- P2: dictation "", Japanese, starting with `--folder`; selection "", plain, multi-line with
  quotes, `$HOME`, backquotes, `$(...)`, Japanese and a leading `-`, a line ending in a newline;
  old clipboard plain or ending in a newline; herdr-app succeeds, fails with one-line JSON,
  multi-line JSON, no output, or is missing; VOICE_SWITCH_APP unset or set. 240 combinations.
- P3: herdr-app fails with multi-line JSON, is missing, or succeeds.
- P4: gaps 0.05, 0.1, 0.2, 0.3, 0.4, 0.6 s, a Cmd+C stub that lands 0.3 s late as the real one
  does, the real `sleep 0.2`, herdr-app taking 0.5 s.
- P5: dictation empty or not.

## Not covered

- How the real herdr-app treats the JSON. The stub accepts only the shape that worked with real
  tabs on 2026-11-06 (herdr-core 0.1.18): one JSON object, `argv` `["claude","--"]`, a string
  `task`. Then `- 項目1`, `42`, `null`, `{"a":1}`, `"引用"` and a tab/quote/backslash/`$HOME`
  mix all reached Claude Code intact (`hc get` showed `"--","<task>"` in argv, `turn` 1). Before,
  `--task` values starting with `-` stopped claude at `error: unknown option`, and values that
  parse as JSON were dropped. Recheck with throwaway tabs after a herdr-core update.
- Non-text clipboard content (images, files): `pbpaste` and `pbcopy` carry text only, so such a
  clipboard comes back as empty text. Fixing it needs the pasteboard's typed items (NSPasteboard),
  not pbpaste.
- The real clipboard under two racing sends (P4 uses a timing stub), onFail.transform, builtin
  outputs, synchronous shells, the HUD pill (verify-keypipe-hud-flow).
- The banner text. On 2026-11-06 the unified log showed the job's notification delivered and
  presented (`usernoted` Delivering/Presenting, `interruptionSuppression: none`), but the log hides
  the body, so what the banner showed was not seen.

## Known findings

None. F1 (trailing newlines lost), F2 (the clipboard words cut off by the 200-character limit),
F3 (prompts starting with `-` or parsing as JSON never reached Claude Code) and F4 (two sends
fighting over the clipboard) were fixed on 2026-11-06 and are now P2, P3, P2 with the stub's JSON
shape, and P4.

## Real bug or modeling error

Read the failing case first. A real bug is one where the code broke a property above: rerun the
case by hand with the same config (P1 writes `config.json` into a temporary folder; copy the
`p1_case` body) and read jobs.log. A modeling error is one where the expected value in check.sh
no longer matches an intended change. Then change the property here first, with the reason, and
check.sh to match. Never loosen an expected value only to get a pass. If a property is meant to
change, show the new check failing on the old behavior before you trust it.

## Proved able to fail (2026-11-06)

Each of these breaks of the real code turned the check red, and restoring it turned it back to
`ALL PASS`:

- M1 the notification uses the token instead of `Failure.message` (Engine.swift, run): 8 P1 cases.
- M2 the reason is the first stderr line instead of the last (Engine.swift, shellStage): 16 P1 cases.
- M3 onFail.output gets `Failure.message` as `KEYPIPE_FAILURE`: 12 P1 cases.
- M4 herdr-claude.sh passes herdr-app's multi-line error unchanged: 45 cases (P2 failML).
- M5 `fail()` in herdr-claude.sh no longer copies the prompt: 178 cases (P2 and P3).
- M6 selection-prompt.sh takes no lock: 9 cases (P4).
- M7 selection-prompt.sh ignores a failed Cmd+C: 5 cases (P5).
- M8 herdr-claude.sh passes the prompt as `--task`: 463 cases (P2 and P3).
- M9 herdr-claude.sh passes `argv` `["claude"]` without `--`: 176 cases (P2).

To break a file that is not committed yet, copy it first and restore from the copy:
`git checkout -- <file>` restores the last commit and throws away uncommitted work.

## Coverage record

Last confirmed that this check describes the code at commit `471df00` plus the changes on branch
`fix/remaining-review` (2026-11-06). Move it to that branch's merge commit once it lands.

| Check | Covers |
|-------|--------|
| P1 | `Failure` (token, message), `ShellStage`, `shellStage`, the notify calls in `run(_:_:_:_:_:)`, `runTransform` in `Sources/keypipe/Engine.swift`; `runShell` stderr return and `notifyUser` in `Sources/keypipe/Shell.swift`; `runJobProcess` and `jobConfig` in `Sources/keypipe/Job.swift`; `--rule` and `--report` in `Sources/keypipe/main.swift` |
| P2, P4, P5 | all of `shell/herdr-claude.sh` and `shell/selection-prompt.sh` |
| P3 | the two above joined, as configured in `~/.config/keypipe/config.json` (rule `herdr-claude`) |

To see whether the covered code moved since then:

```sh
git log --oneline 471df00..HEAD -- Sources/keypipe/Engine.swift Sources/keypipe/Shell.swift Sources/keypipe/Job.swift Sources/keypipe/main.swift shell/herdr-claude.sh shell/selection-prompt.sh
```

Move the commit above forward only after you have read the changed lines and confirmed that the
properties, the bounds and the expected values in check.sh still describe them, and the check
passes at the new commit. For bringing it back in line after changes that skipped this, use
`/maintain-formal-verification-skill`.
