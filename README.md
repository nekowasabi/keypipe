# keypipe

English | [日本語](README.ja.md)

keypipe is a Mac background daemon, Espanso-like. Type a trigger such as
`@@@` in a text field and keypipe takes the field's text, runs it through a
configured transform (any shell command: a script, `claude -p`, `curl`), and
hands the result to a configured sink (replace the field, or any shell
command: tmux, a webhook, the clipboard). There is deliberately no menu bar
UI. Configuration lives in one JSON file. The design is in
`docs/design/context-rules.md`.

## Requirements

- macOS 13 or later, Xcode 15 or Swift 5.9 toolchain.
- The Linux build runs the whole pipeline against a fake desktop
  (`--context` plus `--feed-stdin` or `--smoke-feed`), which is the unit-test
  path. The real key tap and Accessibility access are macOS only.

## Build

```sh
swift build
```

## Run

```sh
mkdir -p ~/.config/keypipe && cp config.example.json ~/.config/keypipe/config.json
make            # stop the running daemon, swift build, start it again
make status     # pid and the last log lines
make stop
# or by hand, pointing at any file
.build/debug/keypipe --config /path/to/keypipe.json &
```

`make` (the `dev` target) is the quick manual-check loop: `make stop`,
`make build`, `make start`. `start` runs the daemon with `nohup`, writes
stdout and stderr to `~/.local/state/keypipe/keypipe.log` (override with
`LOG=`), and fails if `keypipe started` does not appear within 5 s.
`CONFIG=/path.json` passes `--config`. `make log` tails the log, `make test`
and `make verify` run the unit tests and the verification skill
(`VERIFY_ARGS=--no-live` skips the live items).

On start the daemon prints `keypipe started` with the rule count and the
config path. It stays alive until SIGINT (Ctrl-C) or SIGTERM (`kill -TERM`).

Without the key tap, typed input and the desktop state arrive explicitly.
`--context` points at a JSON snapshot of a fake desktop; typed keys append to
its `fieldText`:

```sh
cat > /tmp/ctx.json <<'EOF'
{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello"}
EOF
# Feed one string, fire matched rules, print the final field.
.build/debug/keypipe --config ./config.example.json --context /tmp/ctx.json --smoke-feed '@@@'
# Stream stdin until EOF.
echo '@@@' | .build/debug/keypipe --config ./config.example.json --context /tmp/ctx.json --feed-stdin
```

On a match the daemon prints `keypipe matched <trigger> rule <n>`, then one
line per stage (`erase`, `transform exit`, `apply` or `output-shell exit`),
and finally `keypipe field <json>` with the fake field's text. `--smoke-feed`
exits 0 when a rule matched and 2 when nothing matched. The full line
contract is in `.claude/skills/verify-keypipe-rules/SKILL.md`.

## Config

One JSON file (only the `"json"` format is accepted in MVP; TOML and YAML are
out of scope). Path is passed with `--config` and defaults to
`$XDG_CONFIG_HOME/keypipe/config.json`, which is
`~/.config/keypipe/config.json` when the variable is unset. Without
`--config`, a missing file exits 1 and names that path. Copy
`config.example.json` there to start:

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "when": { "app": ["com.apple.TextEdit"], "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput"
    },
    {
      "trigger": ";;;",
      "when": { "focus": "textField" },
      "output": { "shell": "tmux send-keys -t work:claude -l -- \"$1\"" }
    }
  ]
}
```

- `trigger` is a non-empty string matched as a suffix of recent keystrokes,
  at most 64 characters. When several rules share a buffer, the longest
  trigger wins; among rules with the same trigger, the first one in config
  order whose `when` holds wins. If none holds, nothing fires (no fallback to
  a shorter trigger).
- `hotkey` is the alternative to `trigger` (a rule has exactly one): a chord
  such as `"ctrl+@"` or `"alt+cmd+x"`. Modifiers are `ctrl`/`control`,
  `alt`/`option`, `cmd`/`command`, at least one. Shift is not a modifier but
  part of the key: ctrl+shift+a is written `"ctrl+A"`. The key is the
  character the current keyboard layout produces (`ctrl+@` is the `@` key on
  a JIS keyboard, shift+2 on a US one). A hotkey erases nothing; under
  `focus: textField` the whole field is the input, under `any` the input is
  empty. Chords no rule names (Cmd+C, Cmd+Tab) are ignored without a
  transcript line. The tap is listen-only, so the app in front always
  receives the chord too; keypipe cannot tell whether the app binds it. If an
  app owns `ctrl+@`, scope the rule with `when.app` so keypipe fires only
  where you want it, otherwise both act.
- `when.app` is a list of bundle ids (omit for any app). `when.focus` is
  `textField` or `any` (default). `textField` rules fire only when a text
  element is focused; they erase the trigger and read the field, which
  becomes the input. `any` rules fire anywhere with an empty input; in a text
  element they still erase the trigger. Nothing fires while an input method
  is composing.
- `transform` is optional, a shell command run as `/bin/sh -c`. The input is
  on stdin, in `$1`, and in `KEYPIPE_INPUT`; the front app is in
  `KEYPIPE_APP`. Its stdout, minus one trailing newline, is the result. A
  non-zero exit, a timeout (`shellTimeout`), or empty output is a failure:
  `onFail.transform` runs if present, otherwise nothing is delivered and a
  notification says why.
- `output` is `"replaceInput"` (writes the result back into the same field;
  requires `focus: textField`), `"notify"`, `"none"` (default), or
  `{ "shell": "..." }`, which receives the result the same way a transform
  receives its input. Clipboard is `{ "shell": "pbcopy" }`, a webhook is
  `curl`.
- `onFail` names a fallback per stage, written exactly like the stage:
  `"onFail": { "transform": "curl ...", "output": { "shell": "pbcopy" } }`.
  `onFail.transform` runs once with the same input when `transform` exits
  non-zero, times out, or prints nothing; its stdout then goes to `output`.
  `onFail.output` runs once with the same result when `output` fails: a
  non-zero or timed-out `output.shell`, or a `replaceInput` whose AXValue
  write did not stick (`ignored`) or whose field vanished during the
  transform (`gone`). The fallback shell sees the reason in
  `KEYPIPE_FAILURE` (`exit <n>`, `timeout`, `empty`, `ignored`, `gone`).
  There is no fallback of a fallback: if it fails too, keypipe notifies.
  Without `onFail`, a failed `replaceInput` notifies the result so the text
  is not lost, and a failed `output.shell` is only logged. A plain retry of
  the same command belongs in the shell (`claude ... || curl ...`); `onFail`
  is for a different destination or for failures the shell cannot see.
- `shellTimeout` (top level, seconds, default 30) is the deadline for every
  shell keypipe runs. Past it, the whole process group is killed.
- Unknown keys, an empty `trigger`, `transform`, or `output.shell`, an
  unknown `output` or `focus`, `replaceInput` without `focus: textField`,
  `onFail.transform` without `transform`, `onFail.output` on an output that
  cannot fail (`none`, `notify`), and a non-positive `shellTimeout` are
  rejected at load with `invalid config: <reason>` and exit 1.

## macOS key tap and Accessibility

`Sources/keypipe/MacKeyTap.swift` installs a listen-only CGEventTap, drops
keypipe's own posted Backspaces (tagged through `eventSourceUserData`), and
hands each event to the engine on a serial queue so a slow transform never
stalls the tap: a key with ctrl, alt or cmd held is a hotkey, anything else
is a character for the text matcher. The character comes from the keycode
and shift state through `UCKeyTranslate` on the current layout, which is
what the app in front does too. `MacDesktop.swift`
implements the `Desktop` primitives over the Accessibility API: the focused
`AXTextField`/`AXTextArea` of the frontmost app is the field, a non-empty
`AXTextInputMarkedRange` means composing, anything else is `nothing`.
Notifications go through `osascript display notification` with the text
passed as an argument. Both files only compile under `#if os(macOS)`.

The daemon refuses to start without Accessibility permission for the
`keypipe` binary (System Settings > Privacy & Security > Accessibility).
`keypipe --probe` prints the grant and the current snapshot as one JSON line
and never prompts. What was measured on a real Mac is in
`docs/design/verification-plan.md`; the live items M0 to M4 of
`.claude/skills/verify-keypipe-rules/verify.sh` drive this path through
TextEdit and System Events.

## Layout

- `Package.swift`: Swift package `keypipe`, executable target `keypipe`,
  test target `keypipeTests`.
- `Sources/keypipe/main.swift`: entrypoint, `--config`, `--context`,
  `--smoke-feed`, `--feed-stdin`, `--probe`, and the macOS daemon loop.
- `Sources/keypipe/Config.swift`: the only JSON boundary, `loadConfig(path:)`
  with reason-specific rejections.
- `Sources/keypipe/Context.swift`: `Focus`, `Field`, `Snapshot`, and the
  pure rule selection (`matches`, `select`).
- `Sources/keypipe/Trigger.swift`: `Trigger` (text or hotkey), `Hotkey`
  parsing, and the pure trigger buffer matcher (longest match first,
  64-character buffer).
- `Sources/keypipe/Engine.swift`: the fire sequence (composing gate, select,
  erase with readback, transform, output).
- `Sources/keypipe/Shell.swift`: `runShell`, the one way keypipe runs a
  command (stdin/`$1`/env, process-group timeout).
- `Sources/keypipe/Desktop.swift`, `FakeDesktop.swift`: the desktop port
  (snapshot, backspace, text, setText, notify) and its JSON-driven fake.
- `Sources/keypipe/MacKeyTap.swift`, `MacDesktop.swift`: the listen-only
  CGEventTap and the Accessibility implementation of the desktop port
  (macOS only).
- `Tests/keypipeTests/`: unit tests for trigger, context, config, shell,
  and engine.
- `config.example.json`: a minimal `focus: any` rule that echoes.

## Format and tests

```sh
swift test
swift-format lint --strict --recursive Sources Tests
```

`swift-format` is the formatter and `.swift-format` at the repo root pins
the style (four spaces). The lint above must exit 0. On Linux the box
toolchain additionally needs
`LD_LIBRARY_PATH=/workspace/keypipe-mvp/scratch/swift-lib` for
`libncurses.so.6` (`verify.sh` exports it when that dir exists).

## Verification

The verification skill for the rule pipeline lives at
`.claude/skills/verify-keypipe-rules/` (`SKILL.md`, `verify.sh`, `probes/`).
The fake-desktop items run anywhere; the live items need a Mac with
Accessibility and Automation grants:

```sh
.claude/skills/verify-keypipe-rules/verify.sh --no-live   # R items
.claude/skills/verify-keypipe-rules/verify.sh             # plus M items (Mac)
```

`.claude/skills/verify-keypipe/` is the older MVP skill and still expects
the pre-revision-3 schema.
