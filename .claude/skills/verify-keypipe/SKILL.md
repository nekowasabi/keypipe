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

```sh
cd /workspace/keypipe
git rev-parse --abbrev-ref HEAD   # expect: feat/mvp-daemon
```

No server to keep alive. Each drive builds once (when the toolchain works)
and runs short-lived checks in isolated evidence dirs. Two instances side by
side are safe: every run writes to its own
`/workspace/keypipe-mvp/scratch/verify-<timestamp>/` dir.

## Doctor

Read-only. Answers "is this checkout worth driving?"

```sh
./verify.sh --doctor   # V0 only: branch, toolchain, repo layout probe
```

`V0` never FAILs on a missing toolchain; it records `swift: missing/broken`
so later items can SKIP honestly.

## Drive

```sh
REPO=/workspace/keypipe ./verify.sh            # full V0..V7 run
REPO=/workspace/keypipe ./verify.sh --doctor   # V0 only
```

V table (each row: exact command run by `verify.sh`, expected result):

| V | SPEC | Command | Expect |
|---|---|---|---|
| V0 | env | `git symbolic-ref --short HEAD`, `swift --version` | branch `feat/mvp-daemon`; swift status logged |
| V1 | S1 | `test -f Package.swift && grep 'name: "keypipe"' Package.swift`; README keyword greps; `.gitignore` pattern greps | exit 0, all present |
| V2 | S2 | `test -f Sources/keypipe/main.swift`; `! grep -rq 'NSStatusItem\|NSStatusBar\|import AppKit\|import Cocoa' Sources/`; `grep -rq 'SIGINT\|SIGTERM' Sources/`; `grep -rq 'keypipe started' Sources/`; `swift build`; run `.build/debug/keypipe`, expect start line and survival until SIGTERM | static parts exit 0; build/run SKIP as `MAC_UNVERIFIED` when swift is missing/broken |
| V3 | S3 | `python3 -c json.load(open('config.example.json'))` + `@@@` present; invalid-config run expects non-zero exit or stderr error, else static error-path grep | exit 0 |
| V4 | S4 | `Context` type with `appBundleId`/`processName` fields + always-true stub + test reference | exit 0 |
| V5 | S5 | `TriggerMatcher`/`feed` module + unit test asserting `@@@` detection; hook doc grep (`CGEvent\|AX\|tap`) | exit 0 |
| V6 | S6 | skill files exist with frontmatter; `verify.sh` references S1..S5; harness logs mention `create-verification-skill` and `poteto-mode` | files FAIL if absent; log mentions SKIP when no harness logs are in scope |
| V7 | S7 | `swift-format lint` (or documented equivalent) exit 0; `swift test` exit 0 | SKIP as `MAC_UNVERIFIED` when the tool is missing on Linux |

`verify.sh` exits 0 iff zero FAILs. SKIP never fails the run.

## Evidence

Per-run dir `/workspace/keypipe-mvp/scratch/verify-<timestamp>/` with
`output.log`, `results.tsv` (one row per V item: item, spec, PASS/FAIL/SKIP,
detail), `env.txt`, and any daemon transcripts. The phase-1 proof copy is
pinned at `/workspace/keypipe-mvp/scratch/verify-proof/phase1-proof.log`.

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

Swift on this box is broken (`libncurses.so.6` missing for
`/home/box/swift/usr/bin/swift`), so build/run/format/test items SKIP with
`MAC_UNVERIFIED` until run on macOS or a working toolchain. Static checks
(scaffold, no-menu-bar grep, schema, trigger logic shape) run everywhere and
must PASS. Never weaken a journey to make it pass: a missing file is a FAIL.

## Feature map

`features/README.md` indexes user-facing journeys; one file per journey.
A journey that lacks its seed (e.g. no binary built) reports SKIP/FAIL with
the reason in that file's `Gotchas`, never a weakened assertion.
