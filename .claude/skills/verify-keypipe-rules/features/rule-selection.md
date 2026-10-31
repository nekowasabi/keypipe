# Rule selection

Typing a trigger fires the first rule, in config order, whose `when` matches the frontmost app and focus. If none matches, nothing happens and the typed characters stay.

## Sub-features

- `sel-focus` `when.focus: textField` matches only a focused text field.
- `sel-app` `when.app` matches one of the listed bundle ids.
- `sel-none` no satisfied rule means no erase and no action.
- `sel-order` ties go to the earlier rule.

## How to get to it (user POV)

- Write several rules with the same `trigger` and different `when` in the config, then type the trigger in different apps.

## Driving it with verify.sh

Preconditions:

- Binary built.

- **Focus.** Feed `@@@` with context TextEdit, text field. Item R3a. Transcript has `keypipe matched @@@ rule 1`.
- **App.** Feed `@@@` with context Terminal, no text field. Item R3b. Transcript has `rule 0`.
- **None.** Feed `@@@` with context Finder, no text field. Item R3c. Exit 2, `keypipe nomatch @@@`, no `keypipe erase`.
- **Order.** Two identical rules. Item R3d. `rule 0` wins.
- **Live.** Item M3. Finder frontmost, typed `@@@` adds no `keypipe matched` line.

## Gotchas

- A text area (TextEdit body, multi-line inputs) must count as `textField`. If M1 fails while R4 passes, check how the AX role is mapped.
- JSON decoding ignores unknown keys by default, so an old-schema config would load as a do-nothing rule. R2b catches that. Do not weaken it.
