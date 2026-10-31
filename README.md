# keypipe

English | [日本語](README.ja.md)

keypipe is a Mac background daemon that maps key sequences to actions,
Espanso-like. Type a trigger such as `@@@` and keypipe runs the configured
action (a shell command or a log line). There is deliberately no menu bar UI:
no status item, no preferences window. Configuration lives in one JSON file.

## Requirements

- macOS 13 or later, Xcode 15 or Swift 5.9 toolchain.
- Linux builds run the full matcher/action path via `--feed-stdin` and
  `--smoke-feed`. The macOS key tap is a documented hook point, not wired
  up in this MVP.

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

On Linux and in dev there is no key tap, so typed input arrives explicitly:

```sh
# Feed one string through the matcher and run any matched actions.
.build/debug/keypipe --config ./config.example.json --smoke-feed '@@@'
# Stream stdin line by line through the matcher until EOF.
echo '@@@' | .build/debug/keypipe --config ./config.example.json --feed-stdin
```

On a match the daemon prints `keypipe matched <trigger>`, runs the rule
action, prints `keypipe action exit <status>`, and resets the matcher so the
same trigger can fire again. `--smoke-feed` exits 0 on at least one hit and
2 when nothing matched.

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

- `trigger` is a non-empty string matched as a suffix of recent keystrokes,
  at most 64 characters (`triggerMaxBuffer`). Longer triggers are rejected
  at load because the buffer could never hold them. When several rules match
  the same buffer, the longest trigger wins and ties keep config order.
  Note the streaming caveat: a shorter trigger fires as soon as its own
  suffix matches, before a longer sibling sharing that prefix can complete.
- `action.type` is `shell` (runs `command` via `/bin/sh -c`) or `log`
  (appends `message` to the top-level `logPath`, or prints it when `logPath`
  is null). A shell action without a command, or any other type, is rejected.
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
and only compiles under `#if os(macOS)`. The matcher itself is already wired
into the daemon path (`main.swift` builds it from the loaded rules and runs
actions on hits); until the tap lands, `--feed-stdin` and `--smoke-feed`
prove that path on Linux, and the pure `TriggerMatcher` buffer pipeline is
exercised by unit tests with no Accessibility API.

## Layout

- `Package.swift`: Swift package `keypipe`, executable target `keypipe`,
  test target `keypipeTests`.
- `Sources/keypipe/main.swift`: entrypoint, `--config` parsing, `keypipe
  started` log, SIGINT/SIGTERM handling, run-until-signal loop, plus
  `--feed-stdin` and `--smoke-feed` dev input paths that feed the matcher
  and execute actions.
- `Sources/keypipe/Config.swift`: JSON schema types and `loadConfig(path:)`
  with boundary validation.
- `Sources/keypipe/Actions.swift`: `runAction(_:logPath:)` executes a
  matched rule's `shell`/`log` action.
- `Sources/keypipe/Context.swift`: optional per-rule context plus the
  always-true stub matcher.
- `Sources/keypipe/Trigger.swift`: pure trigger buffer matcher
  (`feed`/`reset`/`buffer`, `triggerMaxBuffer` capacity, longest-match-first).
- `Sources/keypipe/MacKeyTap.swift`: future CGEvent hook documentation.
- `Tests/keypipeTests/`: unit tests for trigger, context, and config.
- `config.example.json`: example mapping `@@@` to `echo keypipe-triggered`.

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

The project-local verification skill lives at
`.claude/skills/verify-keypipe/` with `SKILL.md`, `verify.sh`, and
`features/`. Run the full drive with:

```sh
REPO=/workspace/keypipe .claude/skills/verify-keypipe/verify.sh
```
