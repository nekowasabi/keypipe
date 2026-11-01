# No pane leak from the daemon

iTerm2 and Ghostty show the whole pane as one AX text field (measured 2026-11-01). A `focus: textField` rule fired by the daemon there reads the whole screen. With a webhook rule that screen would leave the machine. In terminals the daemon must do nothing; the widget and bridge handle the line.

## Sub-features

- `leak-fake` on the fake desktop, a terminal bundle id with a text field holding a secret never reaches `output.shell` and gets no Backspaces.
- `leak-control` the same field in TextEdit is sent whole, so the check can see a leak.
- `leak-live` while typing in a real terminal, `daemon.log` has no `erase 1+` and no `apply`.

## How to get to it (user POV)

- Configure a `textField` rule that sends its input somewhere, open iTerm2, type the trigger at the prompt. Today the whole pane is sent (inferred from the F1 baseline and the live T1 notify text).

## Driving it with verify.sh

- F1-`<term>`: `F-<term>.context.json` is `{"app":"<bundle>","focusIsTextField":true,"fieldText":"LAST LOGIN secret-token-123\nkpv> hello"}`, fed `@@@`. PASS when `F-<term>.sent` does not exist and `F-<term>.out` has no `keypipe erase [1-9]`.
- F2 is the same with `com.apple.TextEdit` and must PASS before F1 is trusted.
- T2/T3 assert the live daemon is silent through `<id>.delta.log`.

## Gotchas

- Terminals are recognized by owning `/dev/ptmx`, carried in `--context` as `ownsPty`. F1-unknown uses a made-up bundle id so a hard-coded list fails it.
- Measured holders on 2026-11-01: iTerm2, ghostty, wezterm-gui, herdr (and every zsh, which is never frontmost). Editors with an integrated terminal (VS Code) are out of scope by decision (2026-11-01). If one holds `/dev/ptmx` in its main process, its editor fields are treated as a terminal and the daemon stays silent there (not measured).
- Rejected alternatives: a bundle-id list (the user maintains it, a new terminal leaks until added), `AXRoleDescription` absence (seen only on iTerm2), asking each terminal's own API (Ghostty 1.4 cannot read its screen).
- F1-wezterm is a spec item. The real WezTerm reports `focus: none` (T0), so its live leak path is empty input, not the pane.
