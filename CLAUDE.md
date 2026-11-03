# keypipe: rules for agents

Before claiming done, run `make check` (build, `swift test`, `make lint`, `make check-docs`;
CI runs the same command). Behavior on a real Mac: `make verify-auto`, then the skills in
`.claude/skills/`.

## Rule table

When the operator corrects you, fix the mistake and add a row. A row with no enforcer that
gets repeated must move up to a check in the same change. Drop a row once the mistake can't happen.

| Rule | Enforced by | Past mistakes |
|------|-------------|---------------|
| A bad command line exits 2 before the config is read; it never starts the daemon or runs one of two modes. A missing name under `--rule` exits 2 after loading, like a nonmatching `--line` | the single parse in `Sources/keypipe/main.swift` (`refuse`), R2p/R2r/R2u/R2x in `verify-keypipe-rules`, `EngineTests` testFireRule* in `make check`, P1/P3 in `verify-keypipe-rule-by-name` (manual) | dbb4e06, 2e33ff3, bd121ba, a0a9081, 285184d, 0017de2 |
| A new flag goes into `takesValue` or `alone` in that parse, and a new mode into `modes`; never look up `CommandLine.arguments` elsewhere | review only (judgment) | bd121ba |
| Run the formatter only through `make lint`; scripts do not look for swift-format themselves | `Makefile` `FORMAT`, R1c and V7a call `make lint` | 28de2bc, 8630c35 |
| Checks run the binary or `swift test`; never grep Sources for type or function names | V4a/V5a/V5d were deleted; review only | da918df, 8d3bd48 |
| Backticked `camelCase` and `Type.member` in README and SKILL.md must exist in Sources or Tests | `make check-docs` (`scripts/check-doc-symbols.sh`) | 722248c, 9041e36, `Sink.allCases` |
| Exit codes and `blocked` reasons: change README.md, README.ja.md and the design doc in the same commit as the code | review only; not generated yet | 285184d, 0017de2, 5d3045d |
| Delete code no product path calls instead of keeping it for tests | review only | 5d3045d (`hasSlowTerm`), 8d3bd48 (`select`, `matches`) |

Exceptions to `check-docs` go on the line as
`<!-- docsym-ok: reason, expires YYYY-MM-DD, approved-by NAME -->`.
