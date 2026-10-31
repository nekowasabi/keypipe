---
name: verify-keypipe-rules
description: Verify keypipe's context-rule pipeline (trigger, when, transform, output) from docs/design/context-rules.md on macOS. Drives the real binary with a fake desktop (--context + --smoke-feed) and, on a Mac, the live CGEventTap and AX path through TextEdit via System Events. Use after touching Sources/keypipe, config.example.json, or before claiming a context rule works.
---

# verify-keypipe-rules

Proves the rules in `docs/design/context-rules.md` behave as the user sees them. Two harnesses.

- **Fake desktop.** `keypipe --config C --context X.json --smoke-feed KEYS`. Real config loading, real rule selection, real shell execution. Only the desktop (focus, field text, erase, builtin sinks) is replaced by `FakeDesktop`, which is the production boundary.
- **Live Mac.** The daemon with the real CGEventTap and AX. Keys typed by `System Events`, end state read back from TextEdit by AppleScript.

Target is macOS only. Run it on a Mac. On Linux, R0a fails and the live items skip by design.

## Launch

```sh
.claude/skills/verify-keypipe-rules/verify.sh            # everything
.claude/skills/verify-keypipe-rules/verify.sh --no-live  # skip M items (no Accessibility needed)
```

The script builds with `swift build` (R1a). There is no server for the fake harness; every feed is a fresh process. The live harness starts one daemon in the background, ready when `daemon.log` contains `keypipe started`, and stops it on exit.

## Doctor

```sh
.claude/skills/verify-keypipe-rules/verify.sh --doctor
```

Read-only. Reports the host OS, the swift toolchain, and, when the binary exists, `keypipe --probe` (Accessibility trust and the current snapshot). Run it first whenever anything looks off.

Live items need two Accessibility grants in System Settings > Privacy & Security > Accessibility: the built `keypipe` binary (for the tap and AX) and the terminal running the script (for `System Events` keystrokes). The terminal also needs Automation grants for TextEdit and System Events; the first `osascript` call raises the dialog and blocks until it is answered (AppleEvent timeout -1712 after about 60 s). Set the input source to ABC and pause any espanso trigger that shares a prefix with the test triggers.

Throwaway probes that settled the design's runtime risks live in [`probes/`](probes/) (`axprobe.swift`, `tap.swift`, `imsel.swift`); build each with `swiftc -O -o <out> <file>`. Results are in `docs/design/verification-plan.md`.

## Contract the script asserts

Transcript lines the binary prints, in both harnesses.

| Line | Meaning |
| --- | --- |
| `keypipe started ...` | daemon ready |
| `keypipe matched <trigger> rule <n>` | rule `n` (0-based config index) chosen |
| `keypipe nomatch <trigger>` | trigger typed, no rule's `when` satisfied |
| `keypipe erase <count>` | Backspaces sent for the trigger |
| `keypipe transform exit <status>` | transform finished |
| `keypipe apply <sink> <json-string>` | builtin sink applied |
| `keypipe output-shell exit <status>` | output.shell finished |
| `keypipe field <json-string>` | FakeDesktop only, final field text |

Context JSON for `--context`: `{"app":"<bundle id>","focusIsTextField":true,"fieldText":"...","composing":false,"ignoresBackspace":false}`. Typed keys append to `fieldText`; erase removes from its end. A rule only reads the field when it declares `"when":{"focus":"textField"}` (design revision 3); `focus: any` rules get an empty input, so every item that asserts field text through `$1` or stdin declares `textField`.

`--smoke-feed` exits 0 when at least one rule matched, 2 when none, 1 on invalid config.

Invalid configs print `invalid config: <reason>` with one of these reasons, which R2 matches literally: `empty trigger`, `unknown key <name>`, `unknown output <value>`, `empty output.shell`, `empty transform`, `unknown focus <value>`. A rejection with any other reason fails the item.

`--probe` prints one JSON line: `{"trusted":bool,"app":...,"focusIsTextField":bool,"fieldText":...}`.

## Items

| ID | What | Harness |
| --- | --- | --- |
| R0a/R0b | macOS host, swift toolchain | doctor |
| R1a-c | build, `swift test`, `swift-format lint --strict` | build |
| R2a-f | invalid configs exit 1 with `invalid config` (empty trigger, old `action` key, unknown output, empty `output.shell`, empty `transform`, unknown `focus`) | fake |
| R2g | minimal rule accepted with defaults | fake |
| R3a-d | rule selection by focus, by app, none satisfied (no erase), config order on ties | fake |
| R4a/b | trigger erased before the field is read | fake |
| R5a | transform gets input on stdin, `$1`, `KEYPIPE_INPUT`, and app in `KEYPIPE_APP` | fake |
| R5b | one trailing newline stripped from transform output | fake |
| R5c | failing transform applies nothing, notifies, keeps field | fake |
| R6a/b | output.shell gets the result as `$1` and stdin (side-effect file) | fake |
| R6c | output.shell drives a real tmux pane on an isolated socket | fake + tmux |
| R7 | Japanese text intact end to end | fake |
| R8 | field text with `$()`, backticks, quotes passes through transform and output.shell unexecuted and byte-exact | fake |
| M0 | Accessibility granted to keypipe (M0a); daemon prints `keypipe started` within 5 s (M0b, gates M1-M4) | live |
| M1 | TextEdit `hello@@@` becomes `HELLO` | live |
| M2 | TextEdit `abc;;;` sends `abc` to output.shell, field left as `abc` | live |
| M3 | Finder frontmost, `@@@` is seen (`nomatch` +1), no rule fires, daemon still alive | live |
| M4 | iTerm2 probe recorded (risk check, not a behavior claim) | live |

Feature recipes live in [`features/`](features/README.md).

## Evidence

Per run: `.verify-evidence/rules-<timestamp>-<pid>/` in the repo (gitignored). Override with `KP_EVIDENCE`.

- `results.tsv` one row per item with PASS, FAIL, or SKIP.
- `env.txt` commit, OS, swift, tmux.
- `<item>.config.json`, `<item>.context.json`, `<item>.out`, `<item>.exit` for every feed.
- `*.sent` files written by output.shell, `R6c.pane`, `M*.text`, `daemon.log`, `*.probe.json`.

Proof standard. A PASS needs the action and the resulting state: the transcript line plus the final field or the side-effect file. A transcript line alone is not proof of a sink. Do not report an M item as verified from an R item.

## Cleanup

The `EXIT` trap kills only PIDs the run started (recorded in `daemon.pid`) and the tmux server on the run's own socket `kpv-<pid>`. It never touches the evidence dir, and prints `FAIL cleanup removed evidence` if `results.tsv` is gone. M1 closes its TextEdit document without saving.

## Isolation

Fake feeds are independent processes and can run in parallel. Live items cannot: two daemons would both see every keystroke. Do not run the live part while another keypipe daemon is running, and do not type during M1 to M3.

## Status

Written before the implementation (design revision 2). Every R and M item is expected to FAIL until the code lands. Never executed yet; the first Mac run is the proof of this skill.
