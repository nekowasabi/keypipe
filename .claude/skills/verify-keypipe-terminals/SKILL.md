---
name: verify-keypipe-terminals
description: Verify that keypipe rules (replaceInput like @@@ -> HELLO, and output.shell like a webhook that sends the line) work at a zsh prompt in iTerm2, WezTerm and Ghostty the same way they work in TextEdit, through the zsh line bridge (shell/keypipe.zsh calling keypipe --line). Covers the bridge contract, the widget under tmux, the whole-pane leak hazard on a fake desktop, and the live daemon with System Events keystrokes into windows the run opens itself. Use after touching the bridge, the widget, terminal handling in Engine/MacDesktop, or before claiming a rule works in terminals.
---

# verify-keypipe-terminals

Acceptance items for "rules in the JSON also work in terminals". In TextEdit, `hello@@@` becomes `HELLO` (verify-keypipe-rules M1) and `;;;` sends the field to `output.shell` (M2). At a zsh prompt in iTerm2, WezTerm and Ghostty the same JSON must act on the line being typed. cmux is out of scope. nvim is recorded only.

## Design under test (implemented 2026-11-01)

The JSON stays the only place rules live. zsh's line editor is the terminal's input and output; keypipe's engine runs the rule.

- `shell/keypipe.zsh` is a ZLE widget the user sources from `.zshrc`. It reads `KEYPIPE_BIN`, `KEYPIPE_CONFIG`, and optional `KEYPIPE_APP`. It gets the trigger list once from `keypipe --triggers`. When `LBUFFER` ends with a trigger, it calls the bridge with `BUFFER` minus the trigger and sets `BUFFER` to stdout on exit 0. It never calls `accept-line`.
- `keypipe --config C --triggers` prints each text trigger on its own line, exit 0.
- `keypipe --config C --line <trigger> [--app <bundle id>]` reads the line (trigger removed) on stdin. The line is the focused text field. The rule is selected, transformed and output exactly as a daemon fire would. stdout is the new line: the result for `replaceInput`, the input unchanged for any other output or when a later stage fails. Exit 0 when a rule matched, 2 when none (empty stdout, the widget keeps the trigger), 1 on invalid config. `--app` defaults to the frontmost app (decided 2026-11-01). The harness passes it because under tmux the test has no frontmost terminal of its own.
- `output: {"shell": "...", "background": true}` returns at once, from the bridge and from a daemon fire alike. The transform (if any) and the shell run in a detached job. The job writes its transcript lines to `${XDG_STATE_HOME:-~/.local/state}/keypipe/jobs.log` for checking later, and on failure runs `onFail.output` or notifies. `background` exists only on the shell output, so a `replaceInput` rule cannot ask for it. The job is detached from the caller's session so closing the terminal does not kill it, and ends at the top-level `backgroundTimeout` (seconds, positive, default 300 proposed), which counts as a failure.
- The daemon stays silent in terminals. A terminal is an app whose process holds a pty master (`/dev/ptmx`). Measured 2026-11-01 with `lsof /dev/ptmx`: `iTerm2`, `ghostty`, `wezterm-gui` and `herdr` hold it, TextEdit does not. No bundle-id list. There it does not erase, read the AX field (the whole pane), write, notify, or run shells. This closes the leak F1 shows. `--context` gains `"ownsPty": bool` for the fake desktop.

## Launch

```sh
swift build
.claude/skills/verify-keypipe-terminals/verify.sh --no-live   # B, F, W: no daemon, no GUI, safe while you type
make stop                                                      # live items only; two daemons both see every key
.claude/skills/verify-keypipe-terminals/verify.sh              # adds L, T, N
.claude/skills/verify-keypipe-terminals/verify.sh --only wezterm
```

Every harness uses the same `rules <id>` JSON from verify.sh. That is the user's two `@@@` rules plus `;;;` (output.shell writes `$1` to `<id>.sent`, a local stand-in for a webhook), `%%%` (`rev`, a rule no hand-written widget would contain), and `^^^` (scoped to TextEdit). Each pane runs [`session.sh`](session.sh). It is an interactive zsh with prompt `kpv> `. Return appends `BUFFER` to `<id>.recv` and runs nothing, and it sources `kp.env` (bridge env and the widget) when present. It is ready when `<id>.recv` exists.

W items run that zsh inside tmux on the run's own socket `kpw-<pid>` and type with `tmux send-keys -H` (hex, because tmux eats a trailing `;`). Live items open terminal windows:

| Terminal | Bundle id | Open |
| --- | --- | --- |
| iTerm2 | `com.googlecode.iterm2` | AppleScript `create window with default profile command` |
| WezTerm | `com.github.wez.wezterm` | `wezterm start --always-new-process -- /bin/sh session.sh ...`, raised by pid through System Events |
| Ghostty | `com.mitchellh.ghostty` | `open -na Ghostty.app --args --quit-after-last-window-closed=true -e /bin/sh session.sh ...` |

## Doctor

```sh
.claude/skills/verify-keypipe-terminals/verify.sh --doctor --no-live   # B/F/W prerequisites
.claude/skills/verify-keypipe-terminals/verify.sh --doctor             # adds the Accessibility check
```

Read-only. D0a macOS, D0b binary built, D0g tmux, D0f widget present (SKIP when absent; W and T then fail on their own), D0c no other keypipe (SKIP, it only blocks live items; never killed by the script), D0d terminals installed, D0e nvim, D0h Accessibility (live only).

Live preconditions: Accessibility for the binary and the running terminal, Automation for System Events, input source ABC (the script selects it before each typing step and restores the original), no text expander owning a prefix of a test trigger, hands off the keyboard and mouse (a person typing during the first run on 2026-11-01 produced `まｒけｒ` and lost windows).

## Items

| ID | What | Harness |
| --- | --- | --- |
| B0 | `--triggers` lists `@@@` and `;;;`. Gates B1-B8: when it fails each B item fails with `bridge not implemented` instead of hanging in the daemon loop | bridge |
| B1 | `@@@` on `hello`: exit 0, stdout `HELLO` | bridge |
| B2 | `;;;` on `fix the flaky test`: stdout is the line, `B.sent` is the line | bridge |
| B3 | `%%%` (`rev`) on `abc`: `cba` | bridge |
| B4 | `^^^` (TextEdit only) with a terminal app: exit 2, empty stdout | bridge |
| B5 | `$(...)`, backticks and quotes pass byte-exact to stdout and `.sent`, the embedded `touch` never runs | bridge |
| B6 | `こんにちは abc` becomes `こんにちは ABC` | bridge |
| B7 | transform exits 3: exit 0, stdout is the original line | bridge |
| B8 | `shellTimeout: 1`, transform `sleep 5`: returns the original line within 3 s | bridge |
| J1 | background shell (`sleep 2`, then write `$1`) through the bridge: returns within 1 s with the line, `.sent` absent at return and equal to the line 4 s later, `jobs.log` has `output-shell exit 0` | bridge |
| J2 | background shell `exit 7`: bridge returns the line, `jobs.log` has `output-shell exit 7` and `apply notify` | bridge |
| J3 | the same background rule fired by the daemon in TextEdit (`--smoke-feed`): returns within 1 s, `.sent` is `note` later | fake desktop |
| J4 | bridge called inside a tmux session that is killed right after it returns: `.sent` still appears (job survives closing the terminal) | bridge + tmux |
| J5 | `backgroundTimeout: 2`, job `sleep 10`: no `.sent`, `jobs.log` has `output-shell timeout 2` and `apply notify` | fake desktop |
| J6 | `backgroundTimeout: 0`: exit 1, `invalid config: backgroundTimeout must be positive` | config |
| F1-`<term>` | context = terminal bundle id with `ownsPty:true`, `focusIsTextField:true`, two-line field with `secret-token-123`, `textField` rule sending `$1`: no `.sent`, no `erase 1+`. `<term>` includes `unknown` (`com.example.someterm`), so a bundle-id list cannot pass | fake desktop |
| F2 | same with TextEdit and `ownsPty:false`: `.sent` holds the whole field (control: F1 can see a leak) | fake desktop |
| W1 | `hello@@@` Return: recv `HELLO` | tmux + zsh |
| W2 | `fix the flaky test;;;`: recv is the line without trigger, `W.sent` is the line | tmux + zsh |
| W3 | `abc%%%`: recv `cba` (proves the widget delegates to the JSON) | tmux + zsh |
| W4 | `marker` Return, `hello@@@`: recv `marker`, `HELLO` (prompt and previous line stay out) | tmux + zsh |
| W5 | `hello@@`: recv unchanged (no false fire) | tmux + zsh |
| W6 | `ab cd`, cursor after `ab`, `@@@`: recv `AB CD` (input is the whole line) | tmux + zsh |
| W7 | `hello^^^`: recv unchanged (nomatch keeps the trigger) | tmux + zsh |
| L0 / L1 | daemon started / alive at the end | live |
| T0/T1-`<term>` | probe and daemon transcript while typing, recorded | live |
| T2-`<term>` | `hello@@@`: recv `marker`, `HELLO`; daemon delta has no `erase 1+` and no `apply` | live |
| T3-`<term>` | `fix-the-flaky-test;;;`: recv `marker`, line; `L.sent` exactly the line (no pane text); daemon silent | live |
| N-`<term>` | nvim insert `hello@@@`, Esc, `:wq`, recorded only | live |

W5 and W7 pass before the widget exists. They are guards against a widget that fires too eagerly, not evidence that it works.

Feature recipes are in [`features/`](features/README.md).

## Evidence

`.verify-evidence/terminals-<timestamp>-<pid>/` in the repo (gitignored), or `KP_EVIDENCE`.

- `results.tsv`, `env.txt` (commit, OS, terminal, tmux and nvim versions, widget path).
- B: `B.config.json`, `B<n>.in/.out/.err/.exit`, `B.sent`.
- J: `J<n>.config.json/.in/.out/.err/.exit`, `J<n>.sent`, `state/keypipe/jobs.log` (`XDG_STATE_HOME` points into the evidence dir).
- F: `F-<term>.config.json/.context.json/.out/.exit`, `F-textedit.sent`.
- W: `W.config.json`, `kp.env`, `W<n>.recv` (what zsh received), `W<n>.pane` (tmux capture), `W.sent`.
- Live: `live.config.json`, `daemon.log`, per window `<id>.recv`, `<id>.delta.log`, probes, `<id>.spawn.log`, `L.sent`.

Proof standard. A PASS needs the received line (`.recv` or bridge stdout) and, for `output.shell`, the side-effect file. Screen text and AX values are not proof.

## Cleanup

The `EXIT` trap sends TERM to the daemon and WezTerm processes it started, HUP to every pane program in `<id>.pid` (an interactive zsh ignores TERM), and kills the tmux server on its own socket. Nothing is killed by name. Evidence stays; the trap prints `FAIL cleanup removed evidence` if `results.tsv` is gone.

## Isolation

B, F and W never touch the user's windows and can run while the user's daemon runs. Live items type only into a window whose title contains `kpv-<id>` and whose `--probe` app is the expected bundle id; otherwise the item fails and nothing is typed.

## Status

2026-11-01, after the implementation: full run (`terminals-20261101-115214-37585`) pass=53 fail=0 skip=1. Every B, J, F, W item and T0-T3 in iTerm2, WezTerm and Ghostty pass. The skip is N-iterm2 (its nvim window title never matched `kpv-`; record-only). `make verify-auto` (rules and terminals `--no-live`) is green: rules pass=51 fail=0 skip=2, terminals pass=36 fail=0 skip=1.

Red baseline before the implementation: `terminals-20261101-111639-93608`, pass=11 fail=21 skip=2.

Live harness facts learned on the way, all handled in verify.sh:
- A Japanese IME (ATOK here) turns keystrokes into uncommitted kana. The script builds `probes/imsel.swift` from verify-keypipe-rules, selects ABC before every typing step, and restores the original source in cleanup.
- On this Mac a typed space flips the input source back to ATOK in iTerm2 (cause unknown, likely the user's IME settings). The live T3 line therefore has no spaces. W2 covers spaces through real ZLE under tmux.
- A second Ghostty instance can take more than 10 s to show its window, so `spawn` waits up to 20 s.
