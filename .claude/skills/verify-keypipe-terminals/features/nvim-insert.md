# nvim insert mode

nvim inside a terminal. Whether `hello@@@` should become `HELLO` here is not decided yet (the user said "not considered, or support only nvim"). The items record what happens and do not count.

## Sub-features

- `nvim-iterm2`, `nvim-wezterm`, `nvim-ghostty` the same keystrokes in each terminal.

## How to get to it (user POV)

- In a terminal, `nvim --clean`, `i`, type `hello@@@`.

## Driving it with verify.sh

- N-`<term>` opens `session.sh ... nvim`, types `hello@@@`, Esc, `:wq`, Return. `N-<term>.recv` is the saved file; `N-<term>.delta.log` the log lines.
- When nvim support is chosen, turn N into an acceptance item: file is exactly `HELLO`, no `apply-failed`.

## Gotchas

- nvim lives at `/etc/profiles/per-user/takets/bin/nvim` (nix) on this Mac, not under Homebrew; N items SKIP only when `command -v nvim` finds nothing.
- Esc then `:wq` is sent only if our window is still frontmost; otherwise nvim stays open until cleanup kills it, and the file is not written.
- `--clean` skips the user's init.lua. Mappings in the real config (for `@`, insert-mode Esc) are not covered.
