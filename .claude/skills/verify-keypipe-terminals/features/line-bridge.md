# Line bridge

A one-shot `keypipe` call that runs a JSON rule on a line of text and returns the new line. The zsh widget is its only intended caller.

## Sub-features

- `bridge-triggers` `--triggers` lists text triggers so the widget knows what to watch for.
- `bridge-replace` `replaceInput` rules return the transformed line.
- `bridge-shell` `output.shell` rules (a webhook, tmux, a file) get the line as `$1` and stdin; the line comes back unchanged.
- `bridge-scope` `when.app` applies to the terminal app; no match means exit 2 and the trigger stays.
- `bridge-safe` metacharacters and Japanese pass byte-exact; a failing or slow stage returns the original line within `shellTimeout`.

## How to get to it (user POV)

- Not typed directly. Type a trigger at a zsh prompt with `shell/keypipe.zsh` sourced; the widget calls it.
- By hand: `printf hello | keypipe --config ~/.config/keypipe/config.json --line @@@ --app com.googlecode.iterm2`.

## Driving it with verify.sh

- `verify.sh --no-live` writes `B.config.json` and runs B0 first. B1-B8 pipe `B<n>.in` into `--line` and compare `B<n>.out` byte for byte, plus `B.sent` for shell rules.
- PASS means exit code, stdout and side-effect file all match the table in SKILL.md.

## Gotchas

- An unknown flag makes the current binary start the daemon (CGEventTap and all). B0 runs under a 3 s cap so a missing bridge costs 3 s, not eight 20 s hangs.
- `--app` defaults to the frontmost app. Under tmux there is no terminal app of its own and tmux 3.2+ sets `TERM_PROGRAM=tmux` (from tmux's docs, not checked on this machine), so the harness passes `KEYPIPE_APP`. If the implementation reads `TERM_PROGRAM` instead, tmux-in-iTerm2 would lose `when.app` matching (inferred).
- A webhook rule without `background` blocks the prompt until `curl` returns (B8 bounds it with `shellTimeout`). With `"background": true` the bridge returns at once (J1); results go to `jobs.log`, failures notify (J2). The job outlives the terminal that started it (J4) and ends at the top-level `backgroundTimeout` (J5; default proposed 300 s, a guess to tune), which counts as a failure and notifies.
- The stand-in for a webhook writes a file. No HTTP server is started; the shell boundary is where production hands off to `curl`.
