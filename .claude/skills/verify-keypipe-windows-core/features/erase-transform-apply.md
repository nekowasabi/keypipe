# Erase, transform, apply

## Sub-features

- Erase/read (`runAfterBusy`): text trigger in a text field erases the trigger then reads the
  body; `any` erases only in a text field and never feeds the field; hotkey never backspaces
  (V7). Supplied path passes caller stdin for either focus (V8).
- Transform (`runTransform`): absent transform passes input through; ok delivers output;
  nonzero/timeout/empty is one failure; `onFail.transform` runs at most once with the same
  input; without it, failure notifies and preserves the erased field (V9).
- Apply: `replaceInput` only for field rules; `shell`/`notify`/`none`/`typeText`/`background`;
  `onFail.output` only on fallible sinks, at most once; failed `replaceInput` with no fallback
  notifies so the result is not lost (V9–V10).

## How to get to it (user POV)

A rule author sets `trigger` or `hotkey`, `when.focus` (`textField` default vs `any`), an
optional `transform` shell, and an `output`. The observable end state: field rewritten,
notification shown, shell fed, text typed, background job started — or a `FireResult`
(`replaced`/`delivered`/`started`/`failed`/`noinput`) when it cannot deliver.

## Driving it with `dotnet test`

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet test Keypipe.sln --filter "FullyQualifiedName~EmptyTransformOutput|FullyQualifiedName~TransformFallbackRunsOnce|FullyQualifiedName~OutputFallbackRunsOnce|FullyQualifiedName~FailedSpawnIsReported|FullyQualifiedName~TypeTextOnSuppliedPath|FullyQualifiedName~HotkeyReadsField|FullyQualifiedName~AnySuppliesEmptyInput|FullyQualifiedName~FireRuleRunsOnlyThatRule"
```

## Gotchas

- A vanished field (`noinput`) runs no shell and is not a successful delivery.
- `ReplacedMeansField`: only a `textField` rule reports `replaced`; `replaceInput` is rejected
  for `any` rules at config validation.
- Shell argv parity holds only where a POSIX `sh` exists (`sh -c`, `$0=keypipe`, `$1=input`,
  `KEYPIPE_INPUT`); `cmd`/PowerShell quoting is out of scope and must not change configured
  command strings silently.
- Timeouts keep Mac meaning: per-stage `shellTimeout` (default 30 s) vs whole-job
  `backgroundTimeout` (default 300 s).
