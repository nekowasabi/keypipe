# Transform

`transform` is any shell command (a script, `claude -p`, `curl` to an API). It receives the field text, without the trigger, and its stdout becomes the result. Omitted, the input passes through unchanged.

## Sub-features

- `tf-erase` the trigger is erased before the field is read.
- `tf-channels` input arrives on stdin, `$1`, and `KEYPIPE_INPUT`. The app is in `KEYPIPE_APP`.
- `tf-newline` one trailing newline is stripped from stdout.
- `tf-fail` a non-zero exit applies nothing and notifies.
- `tf-utf8` multibyte text is intact.

## How to get to it (user POV)

- Set `"transform": "<command>"` on a rule, focus a text field, type the trigger.

## Driving it with verify.sh

Preconditions:

- Binary built. Context field text `hello`.

- **Erase.** Item R4. `keypipe erase 3`, then `keypipe field "HELLO"` from `tr a-z A-Z`.
- **Channels.** Item R5a. Field becomes `stdin=hello arg=hello env=hello app=com.apple.TextEdit`.
- **Newline.** Item R5b. `echo HELLO` gives field `"HELLO"`.
- **Failure.** Item R5c. `keypipe transform exit 3`, `keypipe apply notify`, no replaceInput, field `"hello"`.
- **UTF-8.** Item R7. `こんにちは 世界` round-trips.

## Gotchas

- `claude -p` and API calls are not exercised; they are just commands. The proof is that any command receives the input and its stdout is used.
- `$1` works because the command runs as `sh -c <cmd> keypipe <input>`. A script called inside must be passed `"$1"` explicitly.
