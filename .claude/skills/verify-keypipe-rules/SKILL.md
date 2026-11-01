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

Live items need two Accessibility grants in System Settings > Privacy & Security > Accessibility: the built `keypipe` binary (for the tap and AX) and the terminal running the script (for `System Events` keystrokes). The terminal also needs Automation grants for TextEdit and System Events; the first `osascript` call raises the dialog and blocks until it is answered (AppleEvent timeout -1712 after about 60 s). Set the input source to ABC. Any text expander (espanso) must not own a trigger that is a prefix of a test trigger (`@@` once was; it has been removed from the user's config, and the live run passes with espanso running). Keys are translated from keycode and shift with `UCKeyTranslate` on the current layout (since the hotkey change), so a `System Events` keystroke for a shifted key now arrives as the shifted character even though the event's stored string is unshifted (`probes/chord.swift` shows both). M6 types the shifted `!!!` to prove it.

Throwaway probes that settled the design's runtime risks live in [`probes/`](probes/) (`axprobe.swift`, `axwrite.swift`, `tap.swift`, `chord.swift`, `imsel.swift`); build each with `swiftc -O -o <out> <file>`. Results are in `docs/design/verification-plan.md`.

## Contract the script asserts

Transcript lines the binary prints, in both harnesses.

| Line | Meaning |
| --- | --- |
| `keypipe started ...` | daemon ready |
| `keypipe matched <trigger> rule <n>` | rule `n` (0-based config index) chosen |
| `keypipe nomatch <trigger>` | trigger typed, no rule's `when` satisfied |
| `keypipe composing <trigger>` | trigger typed mid-IME-composition, nothing fired |
| `keypipe erase <count>` | Backspaces sent for the trigger (`0` when no text element is focused) |
| `keypipe erase-rewrite` | the app ignored the Backspaces; the trigger was removed by writing `AXValue` |
| `keypipe transform exit <status>` | transform finished |
| `keypipe transform timeout <seconds>` / `keypipe transform empty` | transform killed at `shellTimeout` / exited 0 with empty stdout; a failure, so `onFail.transform` runs if present |
| `keypipe fallback transform exit <n>` / `... timeout <s>` / `... empty` | result of `onFail.transform` (run once with the same input and `KEYPIPE_FAILURE`) |
| `keypipe apply <sink> <json-string>` | builtin sink applied (`replaceInput` only after the readback matches) |
| `keypipe apply-failed replaceInput ignored` / `gone` | the AXValue write did not stick / the field handle died; `onFail.output` runs if present, else the result is notified |
| `keypipe output-shell exit <status>` / `keypipe output-shell timeout <seconds>` | output.shell finished / killed at the deadline; nonzero or timeout runs `onFail.output` if present |
| `keypipe fallback output-shell exit <n>` / `keypipe fallback apply ...` | result of `onFail.output`; if it fails too, `apply notify "<trigger> output failed: <reason>"` |
| `keypipe erase-failed trigger-absent` / `rewrite-ignored` | the field did not end with the trigger / the rewrite did not stick; the fire continues with the field as read |
| `keypipe field <json-string>` | FakeDesktop only, final field text |

Line names share prefixes (`erase`, `erase-rewrite`), so a `lacks` check on a bare name matches up to the trailing space: `'keypipe erase '`.

Context JSON for `--context`: `{"app":"<bundle id>","focusIsTextField":true,"fieldText":"...","composing":false,"ignoresBackspace":false,"backspacePerRead":false}`. `backspacePerRead` delivers one queued Backspace per field read, like an app that processes key events between polls; `keysPerRead` does the same for typed keys, like the tap seeing a key before the app has appended it. `ignoresWrite` accepts `setText` but keeps the old text (only observable when the result differs from the field). `"fieldGoneAfter":"erase"` makes the first write after the erase fail and later reads return nil, like a window closed during a slow transform. `writePerRead` applies `setText` on the read after the next one, like Chromium and Electron landing an AXValue write about 12 to 25 ms later (measured with `probes/axwrite.swift`). Typed keys append to `fieldText`; erase removes from its end. A rule only reads the field when it declares `"when":{"focus":"textField"}` (design revision 3); `focus: any` rules get an empty input, so every item that asserts field text through `$1` or stdin declares `textField`.

`--smoke-feed` exits 0 when at least one rule matched (even if a later stage failed), 2 when none, 1 on invalid config.

`--smoke-hotkey <spec>` feeds one chord (`ctrl+@`, `alt+cmd+x`) after the `--smoke-feed` characters, if any; either flag alone is enough.

Invalid configs print `invalid config: <reason>` with one of these reasons, which R2 matches literally: `empty trigger`, `unknown key <name>`, `unknown output <value>`, `empty output.shell`, `empty transform`, `unknown focus <value>`, `rule needs trigger or hotkey`, `rule has both trigger and hotkey`, `hotkey needs a modifier`, `unknown modifier <name>`, `shift is written in the key (ctrl+A)`, `empty hotkey key`, `hotkey key must be one character`, `onFail.transform requires transform`, `onFail.output requires an output that can fail`, `shellTimeout must be positive`. A rejection with any other reason fails the item.

`--probe` prints one JSON line: `{"trusted":bool,"app":...,"focus":"textField"|"composing"|"none","focusIsTextField":bool,"fieldText":...}` (`fieldText` only when `focus` is `textField`). It never prompts and exits 0 even when untrusted.

## Items

| ID | What | Harness |
| --- | --- | --- |
| R0a/R0b | macOS host, swift toolchain | doctor |
| R1a-c | build, `swift test`, `swift-format lint --strict` (`swift format lint` when only the toolchain has it, as on a Mac with Xcode) | build |
| R1d | the Linux build and `swift test` in a `swift:6.0` container (README promises the Linux feed build; a Glibc-only break never shows on a Mac). Skips without Docker; `DOCKER=<binary>` when it is not on PATH. `swift test` gets SIGTERM at 900 s and SIGKILL 30 s later (`timeout -k 30 900` inside the container; the docker client ignores SIGALRM, so the pull itself is not bounded); it fails, not skips, when Docker runs but the `swift:6.0` image cannot be pulled (offline). `--ulimit nofile=131072` makes fd 70000 usable. `ShellTests.testDetachedJobHasItsOwnSessionAndNoInheritedDescriptors` pins setsid and that a held pipe, low and at fd 70000 (200 on a Mac), is not inherited; `ShellTests.testDetachedJobDoesNotStartWhenDescriptorsCannotBeListed` (Linux only) pins that no job starts when the descriptor listing fails | build |
| R2a-f | invalid configs exit 1 with `invalid config` (empty trigger, old `action` key, unknown output, empty `output.shell`, empty `transform`, unknown `focus`) | fake |
| R2g | minimal rule accepted with defaults | fake |
| R2h-l | hotkey config errors: `rule needs trigger or hotkey`, `rule has both trigger and hotkey`, `hotkey needs a modifier`, `unknown modifier <x>`, `shift is written in the key (ctrl+A)` | fake |
| R2u | an unknown argument (`--hepl`) prints `keypipe: unknown argument` and the usage and exits 2 instead of starting the daemon | binary |
| R2v | `--help` and `-h` print the usage and exit 0 | binary |
| R2q | a value that looks like a flag stays the value: `--line --report` is the trigger `--report` in plain mode (one parse; flags are no longer looked up by position) | binary |
| R2r | a flag given twice (`--config A --config B`) exits 2 instead of picking one value | binary |
| R2x | `--report` (or `--app`) without `--line`, and a flag missing its value (`--smoke-feed`), exit 2 instead of starting the daemon | binary |
| R3a-d | rule selection by focus, by app, none satisfied (no erase), config order on ties | fake |
| R3e | `focus: any` in a text field: trigger erased, input empty, field untouched | fake |
| R4a/b | trigger erased before the field is read | fake |
| R4c | Backspaces delivered one per read: the engine waits for all of them, no rewrite | fake |
| R4d | app ignores Backspace: trigger removed by `AXValue` rewrite (`erase-rewrite`) | fake |
| R4e | trigger keys land after the tap sees them: the engine waits for the trigger suffix before erasing | fake |
| R4f | AXValue write lands one read later (Chromium, Electron): `apply replaceInput`, no `apply-failed` | fake |
| R5a | transform gets input on stdin, `$1`, `KEYPIPE_INPUT`, and app in `KEYPIPE_APP` | fake |
| R5b | one trailing newline stripped from transform output | fake |
| R5c | failing transform applies nothing, notifies, keeps field | fake |
| R5d | empty transform output applies nothing, notifies, keeps field | fake |
| R6a/b | output.shell gets the result as `$1` and stdin (side-effect file) | fake |
| R6c | output.shell drives a real tmux pane on an isolated socket | fake + tmux |
| R7 | Japanese text intact end to end | fake |
| R8 | field text with `$()`, backticks, quotes passes through transform and output.shell unexecuted and byte-exact | fake |
| R9a | `shellTimeout: 1`, `transform: sleep 5`, `onFail.transform: tr`: `transform timeout 1`, `fallback transform exit 0`, field `HELLO` | fake |
| R9b | transform and fallback both nonzero: `fallback transform exit 4`, one notify, field kept | fake |
| R9c | empty output, no `onFail`: `transform empty`, notify, field kept | fake |
| R9d | `output.shell` exits 1: `onFail.output.shell` gets `$1` and `KEYPIPE_FAILURE=exit 1` | fake |
| R9e | `ignoresWrite`: `apply-failed replaceInput ignored`, fallback shell gets the result and `ignored` | fake |
| R9f | `fieldGoneAfter: erase`, no `onFail`: `apply-failed replaceInput gone`, `apply notify "HELLO"` | fake |
| R9g | fallback also times out: `fallback transform timeout 1`, notify, finishes inside `cap 20` | fake |
| R9h-k | rejections: `onFail.transform requires transform`, `onFail.output requires an output that can fail`, `unknown key erase`, `shellTimeout must be positive` | fake |
| R9l | catch-all rule (same trigger, no `when`) fires as `rule 1` when rule 0 does not hold | fake |
| R10a | `--smoke-hotkey ctrl+@` under `focus: textField`: field is the input, `erase 0`, no rewrite, result written | fake |
| R10b | hotkey under `focus: any`: empty input, field untouched | fake |
| R10c | unconfigured chord (`cmd+c`): no transcript line, exit 2 | fake |
| M0 | Accessibility granted to keypipe (M0a); daemon prints `keypipe started` within 5 s (M0b, gates M1-M5) | live |
| M1 | TextEdit `hello@@@` becomes `HELLO` | live |
| M2 | TextEdit `1abc;;;` sends `1abc` to output.shell, field left as `1abc` (digit first: TextEdit auto-capitalizes `abc` to `Abc`) | live |
| M2b | TextEdit `1xyz///` under a `focus: any` rule: only the trigger is erased (field `1xyz`), output.shell gets empty input | live |
| M5 | TextEdit `1hello` then `keystroke "@" using control down` under a `ctrl+@` textField rule: field becomes `1HELLO`, nothing erased | live |
| M6 | TextEdit `1xyz!!!` under a `!!!` any rule: shifted key translated to `!`, trigger erased (field `1xyz`) | live |
| M3 | Finder frontmost, `@@@` is seen (`nomatch` +1), no rule fires, daemon still alive | live |
| M7 | Chrome `textarea` (file URL): `hello@@@` becomes `HELLO` through a delayed AXValue write, no `apply-failed`; the tab is closed afterwards | live |
| M4 | iTerm2 probe recorded (risk check, not a behavior claim; terminal behavior is in `verify-keypipe-terminals`) | live |

Feature recipes live in [`features/`](features/README.md).

## Items for the extension design

For `docs/design/extension-architecture.md`. R11a, R11b, R12a-g and R13a are in
`verify.sh` and run with `--no-live`. R11c is covered in-process
(`EngineTests.testJobParsesTheParentsBytesNotTheFile`) because a job reads its
config at start and cannot be raced from outside. M8 and M9 are live items that
are still to do: they need a person at the Mac (Automation prompt, real typing). Property-style
checks are in `verify-keypipe-trigger` (P1-P10).

| ID | PR | What | Harness |
| --- | --- | --- | --- |
| R11a | PR1 | `--line --report` prints one JSON line per outcome and exit 0; without `--report` stdout and exit are byte-identical to today (B1-B8 in `verify-keypipe-terminals` stay the oracle) | fake |
| R11b | PR1 | a background output reports `started` with a job that did spawn. The failing spawn is checked in-process only (`EngineTests.testFailedSpawnIsReportedAsFailedNotStarted`, a stub that returns false); breaking `posix_spawn` from outside is not reliable. On Linux `spawnDetached` also returns false when it cannot list the descriptors to close, pinned per function in ShellTests (see R1d) | fake |
| R11c | PR1 | the job parses the parent's config bytes, not the file (`JobRequest.configBytes`); jobs.log keeps `job rule N from <path>`. In-process only (`EngineTests.testJobParsesTheParentsBytesNotTheFile`): a job reads its config at start and cannot be raced from outside. `configBytes` is optional only so a daemon started from an older binary can still hand jobs to a rebuilt one | fake |
| R12a | PR2 | `when.url` rule matches only with `"facts":{"url":...}` naming its site; another URL, or no `url` fact at all (`absent`, as on the `--line` path and in non-browser apps), falls through to the next rule. `unreadableFacts` is what stops a fire (R12b) | fake |
| R12b | PR2 | two rules on one trigger, rule 0 `url`, rule 1 catch-all: TextEdit context never reads `url` (`reads` list) and fires rule 1; Chrome context with unreadable url stops without firing rule 1 | fake |
| R12c | PR2 | `deny` with `app`+`url` blocks on match (`keypipe deny`); an unreadable url stops the fire with a reason (`keypipe deny-unreadable`); `deny` with `url` alone is `invalid config: deny url requires app`, and an empty list (`"url": []`, which would let every URL through) is `invalid config: empty url list`. The `unreadable` result and the one notification are checked in-process (`FactsTests.testDenyNeedsAppNextToASlowFactAndBlocksWhenUnreadable`): `--line` reads no live fact | fake |
| R12d | PR2 | `"secure": true` context: `keypipe secure <t>`, no erase, no read, no shell | fake |
| R12e | PR2 | terminal context (`ownsPty`): `focus: any` hotkey rule fires with empty input; `focus: textField` rule still `keypipe terminal <t>` | fake |
| R12f | PR2 | after a slow read the gates are taken again, before and after waiting for a late trigger key: another app, another focus kind or a password field, another field of the same app (`Desktop.sameField`, AX `CFEqual` on a Mac), or a field that no longer ends with the trigger stops the fire with no Backspace (`keypipe front-changed`, `blocked` with reason `front-changed`). Same-app cases are in-process (`FactsTests.testSlowReadRetakesTheGatesBeforeErasing`). The real URL script is compiled and its error handler driven in `FactsTests.testFrontTabScriptCompilesAndKeepsRealErrors` (R1b runs it) | fake |
| R12g | PR2 | `when.app: ["com.apple.*"]` matches TextEdit; every existing R3 config still selects the same rule | fake |
| R12h | PR2 | a URL rule with a late trigger key (`keysPerRead`): the re-check after the slow read waits for the key like the fast path, so the rule fires (no `front-changed`) | fake |
| M8 | PR2 | Chrome on a local `file:///tmp/M8.html` textarea with a rule whose `when.url` is `["file:///tmp/M8.html"]` (a `https://github.com/*` rule does not match a `file://` page; use a real GitHub page to test that glob): first fire prompts for Automation; after granting, `hello@@@` becomes the transform result; a denied prompt stops the fire with a notification; TextEdit never prompts. Note whether the prompt survives the 1 s read deadline | live |
| R13a | PR3 | `typeText` via `--line`: `failed ... unsupported`, `onFail.output: notify` runs. Moving the front (another app, a terminal, a password field, another field) during the transform types nothing and fails as `gone`, primary and `onFail.output` alike (`SinksTests.testTypeTextTypesNothingWhenTheFrontMovedDuringTheTransform`, R1b) | fake |
| M9 | PR3 | `typeText` in TextEdit types the transform result after the erased trigger, tagged events not re-matched (no second fire). Repeat with a Japanese input source on and nothing being composed: the result must arrive as written, not reinterpreted by the IME (record what happens; if it is mangled, typeText must refuse non-keyboard-layout input sources). Also switch apps during a slow transform: nothing is typed (`gone`) | live |

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

Stages 1 to 7 of `docs/design/failure-fallback.md` are implemented: `--no-live` passes every R item (R1c uses `swift-format` or the toolchain's `swift format`, and skips only without either), the live items M0 to M6 run against the real CGEventTap and AX (`MacKeyTap`, `MacDesktop`), and per-stage fallbacks (`onFail`, `shellTimeout`, `KEYPIPE_FAILURE`) are covered by R9. Stage 8 (select-all and paste) was dropped: Chromium and a real Electron app accept AXValue writes with a short delay instead of ignoring them (measured 2026-11-01), so `performWrite` waits up to 200 ms for the readback (R4f) and no paste sink exists.
