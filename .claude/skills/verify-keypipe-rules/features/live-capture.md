# Live capture on macOS

The daemon taps real keystrokes with CGEventTap, reads the focused field through AX, erases the trigger with Backspace events, and writes the result back.

## Sub-features

- `live-trust` Accessibility is granted to keypipe.
- `live-replace` a typed trigger in TextEdit replaces the document text.
- `live-shell` a typed trigger sends the field text to output.shell.
- `live-skip` a non-text-field app does not fire.
- `live-iterm` records whether iTerm2's prompt counts as a text field.

## How to get to it (user POV)

- Start `keypipe --config <file>` and type in any app.

## Driving it with verify.sh

Preconditions:

- macOS, Accessibility granted to the binary and the terminal, TextEdit available, no other keypipe running, hands off the keyboard.

- **Trust.** Item M0. `M0.probe.json` has `"trusted":true`.
- **Replace.** Item M1. New TextEdit document, keystroke `hello@@@`. `M1.text` is `HELLO`.
- **Shell.** Item M2. Keystroke `abc;;;`. `M2.sent` is `abc` and `M2.text` is `abc`.
- **Skip.** Item M3. Finder frontmost, keystroke `@@@`. `keypipe matched` count in `daemon.log` unchanged.
- **iTerm2.** Item M4. `M4.probe.json` records `focusIsTextField` while iTerm2 is frontmost.

## Gotchas

- Rebuilding changes the binary, and macOS may revoke its Accessibility grant. Re-run M0 after every build.
- If M1 shows `hello` (trigger erased, not uppercased), the AX write was ignored. That is the Electron-style fallback risk in the design.
- Whether CGEventTap sees `System Events` keystrokes is unverified. If M1 fails with no `keypipe matched` in `daemon.log`, type `hello@@@` by hand once to separate a harness gap from a tap bug.
