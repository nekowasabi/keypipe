# Feature map: keypipe in terminals

Run every feature through `../verify.sh`. `--no-live` covers the first three.

| Feature | File | Items |
| --- | --- | --- |
| Line bridge (`keypipe --line`, `--triggers`) and background shell output | [line-bridge.md](line-bridge.md) | B0-B8, J1-J3 |
| No pane leak from the daemon | [pane-leak.md](pane-leak.md) | F1, F2, T2/T3 daemon-silent part |
| Rules at the zsh prompt | [prompt-replace.md](prompt-replace.md) | W1-W7, T2, T3 |
| What keypipe sees in a terminal | [terminal-view.md](terminal-view.md) | T0, T1 |
| nvim insert mode | [nvim-insert.md](nvim-insert.md) | N |

Shared preconditions: macOS, `swift build`. Live items also need `make stop`, Accessibility for keypipe and the running terminal, input source ABC, hands off the keyboard. The editor baseline is verify-keypipe-rules M1 and M2 (TextEdit).
