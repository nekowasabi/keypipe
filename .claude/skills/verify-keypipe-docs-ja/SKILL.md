---
name: verify-keypipe-docs-ja
description: Verify the Japanese README translation for keypipe (docs only, no Swift build). Checks README.ja.md exists, mutual README links, Japanese content, and preserved technical terms. Use after touching README.md or README.ja.md on docs/readme-ja, or before opening the docs PR.
---

# verify-keypipe-docs-ja

Docs-only driver. Proves the Japanese translation exists and stays faithful
without building Swift or touching `verify-keypipe` behavior. Evidence is a
per-run dir with `results.tsv`, never the translation itself.

## Launch

No server, no build. Each drive runs short-lived greps in the checkout.
Two instances side by side are safe: every run writes to its own
`.verify-evidence/verify-docs-ja-<timestamp>/` dir.

```sh
cd <repo>
git symbolic-ref --short HEAD   # expect: docs/readme-ja
```

## Doctor

Read-only. Answers "is this checkout worth driving?"

```sh
.claude/skills/verify-keypipe-docs-ja/verify-docs-ja.sh
```

Doctor is the script itself: `Vd0` fails when the repo dir is unreachable.
Branch is informational in `env.txt`; the Vd checks gate the result.

## Drive

```sh
.claude/skills/verify-keypipe-docs-ja/verify-docs-ja.sh                      # full Vd1..Vd5 run
EVIDENCE=.verify-evidence/verify-docs-ja-manual .claude/skills/verify-keypipe-docs-ja/verify-docs-ja.sh   # pinned evidence dir
```

V table (each row: exact check run by `verify-docs-ja.sh`, expected result):

| V | SPEC | Check | Expect |
|---|---|---|---|
| Vd1 | docs-ja | `test -s README.ja.md` | exists and non-empty, else FAIL |
| Vd2 | docs-ja | `grep -q 'README\.ja\.md' README.md` | mutual link EN->JA, else FAIL |
| Vd3 | docs-ja | `grep -q 'README\.md' README.ja.md` | mutual link JA->EN, else FAIL |
| Vd4 | docs-ja | `grep -q -e 'キーシーケンス' -e 'デーモン' -e 'バックグラウンド' README.ja.md` | Japanese content present, else FAIL |
| Vd5 | docs-ja | `grep -q -F '@@@'` + `--smoke-feed` + `--config` in README.ja.md | technical terms preserved, else FAIL |

`verify-docs-ja.sh` exits 0 iff zero FAILs. The skill intentionally FAILs
until the translation exists; a stub or missing file is a FAIL, never a SKIP.

## Evidence

Per-run dir `.verify-evidence/verify-docs-ja-<timestamp>/` with
`output.log` (caller redirects stdout here), `results.tsv` (one row per Vd
item: item, spec, PASS/FAIL, detail), `env.txt` (repo, branch, sha), and
`summary.txt` (`pass=N fail=M`). Proof is the translation plus the
resulting state (file sizes, matched terms), not just exit codes.

## Cleanup

Nothing is spawned, so there is nothing to kill. Cleanup removes no evidence
dirs. After any run, confirm `results.tsv` still exists; a cleanup that eats
the proof fails the run. Never touch Swift sources, tests, or config as part
of verification.

## Helpers

`verify-docs-ja.sh` is executable and its invocation is shown above. It needs
only `bash`, `git`, `grep`, `wc`. No Swift toolchain, no network, no secrets.

## Feature map

`features/README.md` indexes the one docs journey; the journey file records
the user-facing path and its gotchas.
