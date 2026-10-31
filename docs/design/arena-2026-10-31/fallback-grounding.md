# Grounding: per-rule failure fallback, loosely coupled, plus the refactor-first plan

## User's goal (restated)

keypipe is a macOS daemon: a trigger typed in a text field sends the field's text through a configured transform to a configured sink, all declared in one JSON config. The user now wants **a fallback when a step fails, declared per rule (per trigger / per processing)**, added to the architecture in a loosely coupled, "plugin-like" way so new fallbacks can be added without touching the core. They want the final architecture proposal, and they want to **improve the current MVP architecture first, then implement features** on top of it.

Read "plugin-like" against the standing constraint "config is the only place behavior is declared; no plugin code, no hot reload". A candidate may argue that the shell boundary already is the plugin seam, or may propose one typed seam, but must not introduce a dynamic plugin runtime. If you think the constraint should change, say so explicitly with the cost.

## Files to read in full

- `/Users/takets/repos/keypipe/docs/design/context-rules.md` (design revision 3, the current target shape; includes the fire sequence, verified facts, synthesis decisions)
- `/Users/takets/repos/keypipe/docs/design/verification-plan.md` (verification plan, measured results)
- `/Users/takets/repos/keypipe/docs/design/arena-2026-10-31/candidate-1.md` and `candidate-2.md` (the two prior candidates; candidate 1 is the base of revision 3)
- `/Users/takets/repos/keypipe/.claude/skills/verify-keypipe-rules/SKILL.md` and `verify.sh` (the transcript-line contract and the items that must keep passing)
- `/Users/takets/repos/keypipe/Sources/keypipe/*.swift` and `/Users/takets/repos/keypipe/Tests/keypipeTests/*.swift` (the current MVP: old schema `trigger` + `action`, `MatchContext` always true, `Actions.swift` runs shell/log, no CGEventTap wired, `--smoke-feed` / `--feed-stdin` only)

## Failure points known today

From revision 3's fire sequence and the measured facts:

1. `composing`: skipped by design, not a failure.
2. `nomatch`: no rule's `when` holds; by design nothing happens. Should a rule be able to say "if no rule matched for this trigger, do X"? Decide.
3. Erase ignored by the app (TextEdit): handled by readback + `AXValue` rewrite. Readback deadline (~200 ms) expiry is a failure point with no defined handling yet.
4. `transform` exits non-zero: revision 3 says "do not deliver, notify". Fixed behavior, not per rule. Timeouts are undefined (a hung `claude -p` blocks the serial fire queue forever).
5. `transform` exits zero with empty stdout: undefined.
6. `output.shell` exits non-zero: logged (`keypipe output-shell exit <status>`), nothing else.
7. `replaceInput` write ignored (Electron, unverified): revision 3 mentions "read back, fall back to select-all + paste" but it is not designed.
8. Field handle stale (app quit, window closed during a slow transform): undefined.
9. Shell timeout for `output.shell` (webhook via curl hangs): undefined beyond `curl -m`.

## What "loosely coupled" must mean here

- Adding a new fallback for a rule is a config edit, not a Swift edit.
- Adding a new *kind* of failure handling (if a kind is needed at all) touches one place in Swift and the transcript contract, not rule selection, not `Desktop`.
- The fallback must be observable in the fake harness (`--context` + `--smoke-feed`) through transcript lines, so `verify.sh` can assert it.
- No second way to express something the shell already expresses.

## Constraints kept

- Config is the only declaration surface. No plugin binaries, no dynamic loading, no TOML/YAML.
- `Desktop` is the only AX/CGEvent boundary. JSON validated only in `loadConfig` with reason-specific errors.
- Transcript lines are an additive contract (`matched`, `nomatch`, `composing`, `erase`, `erase-rewrite`, `transform exit`, `apply`, `output-shell exit`, `field`).
- Lazy: no abstraction with one implementation, delete before add, smallest diff from revision 3.

## Deliverable per candidate

Write to the candidate's own `design.md`:

1. Usage first: the JSON a user writes for (a) translate-in-place with a fallback when `claude -p` fails or times out, (b) send-to-tmux with a fallback when the tmux target does not exist, (c) a rule whose `replaceInput` must degrade when the write is ignored. Show the transcript lines each case prints on the failure path.
2. Type sketch and signatures (Swift, `notImplemented()` bodies), module map under `Sources/keypipe`, derived from the usage.
3. Rationale per `/Users/takets/.claude/skills/architect/references/rationale-template.md`: which failure points above get per-rule handling and which stay fixed policy, why; how a contributor adds the next fallback; what was rejected.
4. **Refactor-first plan**: the ordered steps that take the current MVP code to the improved architecture *before* any new user-visible feature, each step ending in a check that `verify.sh --no-live` (or `swift test`) can run, and the point at which feature work (CGEventTap, MacDesktop, fallbacks) starts. Name files per step.
