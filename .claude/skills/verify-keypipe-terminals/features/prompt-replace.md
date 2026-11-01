# Rules at the zsh prompt

At a zsh prompt, type text then a trigger. The JSON rule for that trigger acts on the line being typed, as it does on a TextEdit field. `@@@` turns the line into capitals. `;;;` sends the line to `output.shell` (a webhook in real use) and leaves it on the prompt without the trigger. Nothing is executed, and earlier lines and the prompt are not part of the input.

## Sub-features

- `prompt-replace` replaceInput rules rewrite the line (W1, W3, T2).
- `prompt-shell` output.shell rules send exactly the line (W2, T3).
- `prompt-line-only` previous lines and the prompt stay out (W4, T2, T3 `marker`).
- `prompt-whole-line` a trigger typed mid-line uses the whole line (W6).
- `prompt-no-false-fire` an incomplete or non-matching trigger leaves the line alone (W5, W7).
- `prompt-iterm2`, `prompt-wezterm`, `prompt-ghostty` the same in each real terminal (T2, T3).

## How to get to it (user POV)

- Add to `.zshrc`: `export KEYPIPE_BIN=... KEYPIPE_CONFIG=~/.config/keypipe/config.json` and `source <repo>/shell/keypipe.zsh`. Start the daemon (`make`). Type `hello@@@` at the prompt.

## Driving it with verify.sh

- W items: `--no-live`. Each opens `session.sh` zsh in a tmux session, types with `send-keys -H`, presses Enter, and reads `W<n>.recv`. `W<n>.pane` keeps the screen for debugging only.
- T2/T3: live. Opens a window per terminal, types `marker` Return, then the trigger line, then Return. `T-<term>.recv` / `S-<term>.recv` and `L.sent` are the proof; `<id>.delta.log` proves the daemon stayed silent.

## Gotchas

- The `kpv> ` zsh is scaffolding. Plugins, autosuggestions, syntax highlighting and vi mode in the user's real `.zshrc` are not covered. Add an item with the user's `ZDOTDIR` once W passes here.
- `zsh -f`, ssh sessions, bash and fish do not get the widget. There the trigger stays as typed and nothing runs (by design).
- tmux reads a `send-keys` argument ending in `;` as a command separator. The harness sends literal text as hex for that reason; a hand repro with `send-keys -l 'x;;;'` drops the last `;`.
- iTerm2 spawn splits its command on spaces, so a repo path with a space breaks it (unverified).
- WezTerm started from a background shell is not activated; the script raises it by pid. If T-wezterm says "never frontmost", that is a harness gap (unverified).
- `wezterm start --always-new-process` loads the user's `wezterm.lua`; `exit_behavior = "Hold"` would keep windows after cleanup (unverified).
- Ghostty `--quit-after-last-window-closed=true` is meant to make the extra instance quit (unverified on 1.4.0).
