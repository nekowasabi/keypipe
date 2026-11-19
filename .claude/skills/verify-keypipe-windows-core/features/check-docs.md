# Feature: CI docs gate (check-docs)

Slice: PR #11 `make check` on macOS runs `scripts/check-doc-symbols.sh`, which fails when
this skill's `SKILL.md` names backtick symbols that are not in Swift `Sources/`/`Tests/`.
This item keeps that gate green without deleting the Windows skill.

## Sub-features

- C# symbols (`Keypipe.Core`, `FireTests.*`, `TriggerMatcherTests.*`, `SinksTests.*`,
  `Keypipe.Core.Tests`) resolve via the `.cs` identifier index in `src/` + `tests/`.
- Repo-root files (`Keypipe.sln`) resolve when the file exists.
- Intentionally absent names for this slice (`SendInput`, `Keypipe.Windows`) carry a
  `<!-- docsym-ok: ... -->` marker on the same line instead of failing.
- Swift-only behavior unchanged: a backtick Swift symbol missing from `Sources/`/`Tests/`
  still fails.

## How to get to it (user POV)

CI (`.github/workflows/check.yml`) runs `make check`, which runs `make check-docs`, which
runs `scripts/check-doc-symbols.sh`. Locally the same command is:

```sh
bash scripts/check-doc-symbols.sh
```

Exit 0 = docs clean. Exit nonzero prints `<doc>:<line>: \`<tok>\` is not in Sources/ or
Tests/` per offending token.

## Driving it with the gate script

One command runs docs + C# together (docs first, so a docs failure short-circuits before
the slower `dotnet test`):

```sh
sh .claude/skills/verify-keypipe-windows-core/check.sh
```

Docs only: `bash scripts/check-doc-symbols.sh`. C# only:
`sh .claude/skills/verify-keypipe-windows-core/verify.sh`.

## Gotchas

- Backtick tokens are the only thing checked (`grep -oE` on backtick spans); prose without
  backticks never fails. `camelCase` single tokens and `Type.member` dotted tokens are
  checked; plain lowercase words and `*.swift|json|md|sh|...` file-suffix tokens are skipped.
- `docsym-ok` suppression is per-line: the marker comment must be on the SAME line as the
  offending token. Putting it on the next line does nothing.
- The script indexes Swift words from `Sources` + `Tests` and C# identifiers from `src` +
  `tests/` (when those trees exist). A C# symbol fails only when no `.cs` identifier part
  matches — check spelling and namespace before adding a suppression.
- Do not "fix" a docs failure by removing true C# test names from the V1–V12 table; fix the
  script index or add a marked deferral instead.
