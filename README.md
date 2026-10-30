# keypipe

keypipe is a Mac background daemon that maps key sequences to actions,
Espanso-like. Type a trigger such as `@@@` and keypipe runs the configured
action (a shell command or a log line). There is deliberately no menu bar UI:
no status item, no preferences window. Configuration lives in one JSON file.

## Requirements

- macOS 13 or later, Xcode 15 or Swift 5.9 toolchain.
- Linux builds for CI smoke checks only. The macOS key tap is a documented
  hook point, not wired up in this MVP.

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

## Config

One JSON file (only the `"json"` format is accepted in MVP; TOML and YAML are
out of scope). Path is passed with `--config` and defaults to
`./config.example.json`. Copy `config.example.json` to start:

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "action": { "type": "shell", "command": "echo keypipe-triggered" },
      "context": { "appBundleId": null, "processName": null }
    }
  ],
  "logPath": null
}
```

- `trigger` is a non-empty string matched as a suffix of recent keystrokes.
- `action.type` is `shell` (runs `command`) or `log` (writes `message`).
  A shell action without a command, or any other type, is rejected.
- `context` is optional. `appBundleId` and `processName` may each be null,
  meaning wildcard. Matching is stubbed in this MVP: every rule always
  matches, but the fields exist and are decoded and tested so a real per-app
  matcher slots in later.
- Invalid config (bad JSON, empty trigger, unknown action type, missing file)
  fails loud: the daemon prints the error to stderr and exits non-zero.

No secrets or network calls belong in actions.

## macOS key tap hook (future, not in MVP)

`Sources/keypipe/MacKeyTap.swift` documents the hook point. A future change
creates a CGEventTap for keyDown events, converts each CGEvent to the typed
character, and feeds it into `TriggerMatcher.feed`. On a hit it executes
`rule.action`. The tap needs Accessibility permission (`AXIsProcessTrusted`)
and only compiles under `#if os(macOS)`. Until that lands, the pure
`TriggerMatcher` buffer pipeline is exercised by unit tests with no
Accessibility API.

## Layout

- `Package.swift`: Swift package `keypipe`, executable target `keypipe`,
  test target `keypipeTests`.
- `Sources/keypipe/main.swift`: entrypoint, `--config` parsing, `keypipe
  started` log, SIGINT/SIGTERM handling, run-until-signal loop.
- `Sources/keypipe/Config.swift`: JSON schema types and `loadConfig(path:)`
  with boundary validation.
- `Sources/keypipe/Context.swift`: optional per-rule context plus the
  always-true stub matcher.
- `Sources/keypipe/Trigger.swift`: pure trigger buffer matcher.
- `Sources/keypipe/MacKeyTap.swift`: future CGEvent hook documentation.
- `Tests/keypipeTests/`: unit tests for trigger, context, and config.
- `config.example.json`: example mapping `@@@` to `echo keypipe-triggered`.

## Format and tests

```sh
swift test
swift-format lint --recursive Sources Tests
```

`swift-format` is the formatter. It is absent from the Linux CI box, so the
format gate is recorded as `MAC_UNVERIFIED` there and must be run on macOS.
Keep new Swift code in swift-format style (four spaces, sorted imports).

## Verification

The project-local verification skill lives at
`.claude/skills/verify-keypipe/` with `SKILL.md`, `verify.sh`, and
`features/`. Run the full drive with:

```sh
REPO=/workspace/keypipe ./verify.sh
```
