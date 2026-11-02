---
name: verify-keypipe
description: Verify keypipe Mac background daemon (key sequence to action, Espanso-like, no menu bar). Covers scaffold, daemon lifecycle, JSON config with @@@ trigger, context stub, trigger pipeline, and quality gates. Use after touching keypipe code or config, when behavior is suspect, or before opening the MVP PR.
---

# verify-keypipe

Drives the real artifact (built binary, example config, unit tests), never
internal setters or test-only endpoints. Proof is the action plus the
resulting state (log lines, files written, exit codes), not just a final
screen. Mocks only where a production boundary already isolates the system
(Mac-only CGEvent tap, absent on Linux).

## Launch

Staging location (phase 1): `/workspace/keypipe-mvp/skills/verify-keypipe/`.
Repo location (phase 2+): `<repo>/.claude/skills/verify-keypipe/`.
Copy with `cp -r /workspace/keypipe-mvp/skills/verify-keypipe
<repo>/.claude/skills/verify-keypipe`.

The script defaults `REPO` to the checkout that holds it and writes evidence
under `<repo>/.verify-evidence/` (gitignored). Set `BRANCH=<name>` to make V0
also require that branch; unset, V0 does not gate on the branch.

No server to keep alive. Each drive builds once (when the toolchain works)
and runs short-lived checks in isolated evidence dirs. Two instances side by
side are safe: every run writes to its own
`.verify-evidence/verify-<timestamp>-<pid>/` dir.

## Doctor

Read-only. Answers "is this checkout worth driving?"

```sh
.claude/skills/verify-keypipe/verify.sh --doctor   # V0 only: branch, toolchain, repo layout probe
```

`V0` never FAILs on a missing toolchain; it records `swift: missing/broken`
so later items can SKIP honestly. `--doctor` exits non-zero when any check
FAILs (wrong branch when `BRANCH` is set), so automation can gate on it.

## Drive

```sh
.claude/skills/verify-keypipe/verify.sh            # full V0..V7 run
.claude/skills/verify-keypipe/verify.sh --doctor   # V0 only
```

V table (each row: exact command run by `verify.sh`, expected result):

| V | SPEC | Command | Expect |
|---|---|---|---|
| V0 | env | `git symbolic-ref --short HEAD`, `swift --version` | branch equals `BRANCH` when set; swift status logged |
| V1 | S1 | `test -f Package.swift && grep 'name: "keypipe"' Package.swift`; README keyword greps; `.gitignore` pattern greps | exit 0, all present |
| V2 | S2 | `test -f Sources/keypipe/main.swift`; `! grep -rq 'NSStatusItem\|NSStatusBar\|NSMenu(' Sources/` (AppKit itself is allowed for `NSWorkspace`); `grep -rq 'SIGINT\|SIGTERM' Sources/`; `grep -rq 'keypipe started' Sources/`; `swift build`; run `.build/debug/keypipe`, expect start line and survival until SIGTERM | static parts exit 0; build/run SKIP as `MAC_UNVERIFIED` when swift is missing/broken |
| V3 | S3 | `python3 -c json.load(open('config.example.json'))` + `@@@` present; invalid-config run expects non-zero exit or stderr error, else static error-path grep | exit 0 |
| V4 | S4 | no item: rule selection is checked by `swift test` (V7b), not by grepping type names | - |
| V5 | S5 | hook doc grep in README (`CGEvent\|AX\|tap`); runtime `--smoke-feed '@@@'` and `'hi @@@ there'` with an `output.shell` rule must log `matched @@@` and `output-shell exit 0` and write `smoke.out` | exit 0; runtime parts SKIP as `MAC_UNVERIFIED` when swift is missing/broken |
| V6 | S6 | skill files exist with frontmatter; `verify.sh` references S1..S5; `phase1.jsonl`/`phase2.jsonl` harness logs mention `create-verification-skill` and `poteto-mode` | files FAIL if absent; SKIP when harness logs are absent, FAIL when logs exist but a skill name is missing |
| V7 | S7 | `make lint` (`swift-format lint --strict --recursive Sources Tests`, config: `.swift-format`, four spaces) exit 0; `swift test` exit 0; long builds/tests use a portable timeout (`timeout`, `gtimeout`, perl alarm, or none on Darwin) | SKIP as `MAC_UNVERIFIED` when swift is missing/broken; a missing formatter is a FAIL |

`verify.sh` exits 0 iff zero FAILs. SKIP never fails the run.

## Evidence

Per-run dir `.verify-evidence/verify-<timestamp>-<pid>/` with
`output.log`, `results.tsv` (one row per V item: item, spec, PASS/FAIL/SKIP,
detail), `env.txt`, and any daemon transcripts. The phase-1 proof copy lived in the MVP box under
`/workspace/keypipe-mvp/scratch/verify-proof/` and is not in this repo.

## Cleanup

Kill only PIDs the run started (recorded in the evidence dir). Never kill by
process name. Cleanup removes spawned processes and temp run dirs, never the
evidence dir. After cleanup, confirm `results.tsv` still exists; a cleanup
that eats the proof fails the run.

## Helpers

`verify.sh` is executable and its invocation is shown above. It needs only
`bash`, `git`, `grep`, `python3`; `swift`/`swift-format` are optional and
their absence becomes a logged SKIP, not a crash.

## Linux note

Swift on this box needs `PATH=/home/box/swift/usr/bin` (already exported by
`verify.sh`) plus `LD_LIBRARY_PATH=/workspace/keypipe-mvp/scratch/swift-lib`
for `libncurses.so.6`. With that set, build/run/format/test items run for
real; they SKIP with `MAC_UNVERIFIED` only when the toolchain is still
missing or broken. Static checks (scaffold, no-menu-bar grep, schema,
trigger logic shape) run everywhere and must PASS. Never weaken a journey
to make it pass: a missing file is a FAIL.

## Feature map

`features/README.md` indexes user-facing journeys; one file per journey.
A journey that lacks its seed (e.g. no binary built) reports SKIP/FAIL with
the reason in that file's `Gotchas`, never a weakened assertion.
