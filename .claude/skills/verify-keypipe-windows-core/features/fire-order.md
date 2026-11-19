# Fire order (the gated procedure)

## Sub-features

- Trigger feed → terminal filter → composing gate → secure gate → deny → candidate rules →
  front re-check → erase/read → background decision → transform → apply (SPEC fire order 1–11).
- V1–V18 in `../SKILL.md` are the gate checklist; every item maps to a C# test name plus a
  `dotnet test --filter "FullyQualifiedName~<Name>"` string. V1–V12 gate the fire order;
  V13–V18 are parity items (glob semantics, hotkey parsing, character counting, label
  capping, load errors, write timing) added by the 2026-11-07 maintain run.

## How to get to it (user POV)

A rule author writes one JSON config (same keys as Mac; `when.app` values and `/bin/sh`
commands are Mac values and are NOT promised to run unmodified on Windows). A caller fires a
rule by typing a trigger, pressing a hotkey, or piping stdin via the supplied path
(`--line`/`--rule` equivalent). The observable end state is the `FireResult` kind
(`replaced`, `delivered`, `started`, `failed`, `nomatch`, `blocked`, `unreadable`, `noinput`)
and the `--report` v1 JSON shape where applicable.

## Driving it with `dotnet test`

```sh
export PATH="$HOME/.dotnet:$PATH"
sh .claude/skills/verify-keypipe-windows-core/verify.sh
sh .claude/skills/verify-keypipe-windows-core/verify.sh --filter "FullyQualifiedName~ComposingDoesNotFireOrErase"
```

Full unfiltered gate first for any green claim; single-V filters only to isolate a failure.

## Gotchas

- Composing and secure stop before deny, erase, and any shell. A test that only asserts "shell
  did not run" is incomplete: assert the `blocked("composing")` / `blocked("secure")` result
  AND no erase AND no shell.
- An unreadable fact stops the fire; it never selects the next rule of the same trigger.
- A trigger whose `when` fails never falls back to a shorter trigger suffix.
- `started` means a background job actually spawned; a failed spawn is `failed`, not `started`.
- If the suite is missing (no `Keypipe.sln`), `verify.sh` FAILs clearly — that is evidence of
  absence, not green. Do not weaken the gate to pass without the port.
