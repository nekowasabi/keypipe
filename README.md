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
  path. The real key tap and Accessibility access are macOS only and not
  wired up yet (stage 6 in `docs/design/failure-fallback.md`).

## Build

```sh
swift build
```

## Run

```sh
swift run keypipe --config ./config.example.json
# or
.build/debug/keypipe --config /path/to/keypipe.json
```

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
`./config.example.json`. Copy `config.example.json` to start:

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
- `when.app` is a list of bundle ids (omit for any app). `when.focus` is
  `textField` or `any` (default). `textField` rules fire only when a text
  element is focused; they erase the trigger and read the field, which
  becomes the input. `any` rules fire anywhere with an empty input; in a text
  element they still erase the trigger. Nothing fires while an input method
  is composing.
- `transform` is optional, a shell command run as `/bin/sh -c`. The input is
  on stdin, in `$1`, and in `KEYPIPE_INPUT`; the front app is in
  `KEYPIPE_APP`. Its stdout, minus one trailing newline, is the result. A
  non-zero exit, a timeout (30 s), or empty output delivers nothing and
  notifies.
- `output` is `"replaceInput"` (writes the result back into the same field;
  requires `focus: textField`), `"notify"`, `"none"` (default), or
  `{ "shell": "..." }`, which receives the result the same way a transform
  receives its input. Clipboard is `{ "shell": "pbcopy" }`, a webhook is
  `curl`.
- Unknown keys, an empty `trigger`, `transform`, or `output.shell`, an
  unknown `output` or `focus`, and `replaceInput` without `focus: textField`
  are rejected at load with `invalid config: <reason>` and exit 1.

## macOS key tap and Accessibility (stage 6, not wired yet)

`Sources/keypipe/MacKeyTap.swift` documents the hook point. The real
implementation installs a listen-only CGEventTap, ignores keypipe's own
posted Backspaces, and calls `Engine.key` after the event is delivered.
`MacDesktop` will implement the `Desktop` primitives over the Accessibility
API. Both need Accessibility permission and only compile under
`#if os(macOS)`. What was measured on a real Mac before implementing is in
`docs/design/verification-plan.md`.

## Layout

- `Package.swift`: Swift package `keypipe`, executable target `keypipe`,
  test target `keypipeTests`.
- `Sources/keypipe/main.swift`: entrypoint, `--config`, `--context`,
  `--smoke-feed`, `--feed-stdin`, `--probe` (stub), signal handling.
- `Sources/keypipe/Config.swift`: the only JSON boundary, `loadConfig(path:)`
  with reason-specific rejections.
- `Sources/keypipe/Context.swift`: `Focus`, `Field`, `Snapshot`, and the
  pure rule selection (`matches`, `select`).
- `Sources/keypipe/Trigger.swift`: pure trigger buffer matcher
  (longest match first, 64-character buffer).
- `Sources/keypipe/Engine.swift`: the fire sequence (composing gate, select,
  erase with readback, transform, output).
- `Sources/keypipe/Shell.swift`: `runShell`, the one way keypipe runs a
  command (stdin/`$1`/env, process-group timeout).
- `Sources/keypipe/Desktop.swift`, `FakeDesktop.swift`: the desktop port
  (snapshot, backspace, text, setText, notify) and its JSON-driven fake.
- `Sources/keypipe/MacKeyTap.swift`: CGEvent hook documentation (stage 6).
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
