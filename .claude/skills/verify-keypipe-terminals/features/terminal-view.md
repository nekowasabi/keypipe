# What keypipe sees in a terminal

Before any change, record per terminal what the AX snapshot is when a terminal window is frontmost. It decides which rule fires and what the input is.

## Sub-features

- `view-focus` `--probe` `focus` is `textField`, `composing` or `none`.
- `view-size` size of the probe JSON. A large one means `fieldText` holds the whole pane (measured on iTerm2: 3,819 characters, `AXTextArea`, settable).

## How to get to it (user POV)

- Bring a terminal window to the front and run `.build/debug/keypipe --probe` from another place, or let verify.sh do it.

## Driving it with verify.sh

- T0-`<term>` writes `T-<term>.before.probe.json` (prompt empty) and `T-<term>.after.probe.json` (after `hello@@@`, before Return). The detail column has `focus` and the byte count.
- Recorded only. It answers "why doesn't it work now" for each terminal.

## Gotchas

- Measured only for iTerm2 so far (`docs/design/verification-plan.md`). WezTerm and Ghostty AX exposure is unknown; that is what T0 is for.
- `AXRoleDescription` missing on iTerm2 (error -25212) is the candidate signal to tell a terminal from an editor. Record it with `probes/axnames.swift` from verify-keypipe-rules when T0 alone does not decide.
