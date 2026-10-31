# Output

`output` is a builtin sink (`replaceInput`, `insert`, `clipboard`, `notify`, `none`) or `{ "shell": "..." }`. Every external destination (tmux, Herdr, Grok Bot, CotEditor, a script argument) is the shell form.

## Sub-features

- `out-replace` `replaceInput` replaces the field with the result.
- `out-shell-arg` output.shell gets the result as `$1`.
- `out-shell-stdin` output.shell gets the result on stdin.
- `out-tmux` a real tmux pane receives the text.

## How to get to it (user POV)

- Set `"output": "replaceInput"` or `"output": { "shell": "tmux send-keys -t work -l \"$1\"" }`.

## Driving it with verify.sh

Preconditions:

- Binary built. For R6c, `tmux` on PATH.

- **Replace.** Item R4. `keypipe field "HELLO"`.
- **Arg.** Item R6a. `R6a.sent` contains `hello`.
- **Stdin.** Item R6b. `R6b.sent` contains `HELLO` after `tr a-z A-Z`.
- **tmux.** Item R6c. Session `kpv` on socket `kpv-<pid>`. `R6c.pane` contains `hello`.
- **Live.** Item M2. `abc;;;` in TextEdit writes `abc` to `M2.sent`.

## Gotchas

- `insert` and `clipboard` have no item yet. Add one before claiming them.
- R6c uses its own tmux socket. Never point it at the user's default server.
