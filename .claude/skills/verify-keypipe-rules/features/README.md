# keypipe rules verification map

The maintained source for verifying context rules. Read this index, then the feature file.

## Baseline preconditions

- macOS host, swift toolchain, built `.build/debug/keypipe`.
- No other keypipe daemon running for live items.
- Accessibility granted to `keypipe` and to the terminal (live items only).

## Driving conventions

- Fake harness: `keypipe --config C --context X.json --smoke-feed KEYS`, assert transcript lines from `SKILL.md`.
- Live harness: daemon in background, keys via `osascript -e 'tell application "System Events" to keystroke "..."'`, state via AppleScript reads.
- Every item writes its config, context and output into the evidence dir.

## Features

- [Rule selection](./rule-selection.md) picks a rule from the trigger and the desktop context.
- [Transform](./transform.md) runs a replaceable shell command over the field text.
- [Output](./output.md) sends the result to a builtin sink or any shell destination.
- [Live capture on macOS](./live-capture.md) proves the real key tap and AX read and write.
