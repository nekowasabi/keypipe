# Fired HUD + rule icon

SPEC: `/workspace/keypipe-mvp/plan/2026-11-02/SPEC-hud.md` (H1-H10).
Status: specified, not implemented. Every H item below FAILs until the
implement phase lands, except the keep-green guards (H3b, H6b-c, H7a/c,
H9a) and H10, which stays MAC_UNVERIFIED (manual Mac proof). Branch
`feat/fired-hud`. Reference only (do not copy wholesale):
`MacApp.swift` HUD / icon loading (~1851+) in voice-switch.

## Sub-features

- `hud-ok` (H1). After a sync fire that reaches `showBusy` and delivers
  (`delivered`, `replaced`), call `hideBusy` then `showFired` exactly once
  with status ok. `.noInput` (field gone after the erase) hides the spinner
  with no pill: there is nothing to report.
- `hud-failed` (H2). On `.failed` after busy, `showFired` with status
  failed and the stage. The existing `notify` is unchanged.
- `hud-started` (H3). On `.started` (background spawn ok), `showFired`
  with status started, once. Never `showFired` for `blocked` (terminal,
  composing, secure, deny, front-changed), `noMatch`, `unreadable`, or any
  fire that never reached `showBusy`.
- `hud-label` (H4). Pill/transcript label text is `<trigger> → <label>`:
  `rule.name` when set; else the primary `output.shell` script truncated to
  its first 40 graphemes (Swift `Character` count, no ellipsis); else the
  builtin sink name. Collapse every run of whitespace (newlines, tabs) to
  one space. Never transform stdout, field text, or stdin.
- `hud-icon` (H5). Optional rule `icon` string: a `.app` path shows that
  app's icon; an image path shows that image; any other short string
  (emoji, text) is drawn as text; omitted means the status glyph only.
  Kind-specific drawing is Mac-only (H10); on Linux the raw string must
  still round-trip through the transcript (H5a-d).
- `hud-flag` (H6). Top-level `hud` bool, default true. `hud: false` means
  never `showFired` and no `keypipe hud` line. Unknown keys are still
  rejected exactly as before (R2, R9h-k stay green).
- `hud-plumbing` (H7). `Desktop.showFired(...)`, protocol default no-op.
  `FakeDesktop` records calls for the in-process proof. `LineDesktop`, jobs
  (`--job`), and the `--line` bridge never draw a pill. Linux builds
  compile with no AppKit outside `#if os(macOS)`.
- `hud-emit` (H8). Every fire that reaches the pill emits exactly one line:
  `keypipe hud <trigger> <status> <label-json> <icon-json>`, where status
  is `ok`, `failed`, or `started`, the label is the H4 text JSON-quoted,
  and the icon is the raw string JSON-quoted or the bare token `none`.
  The SPEC-mandated `keypipe hud <trigger> <status>` is a prefix of it.
  The line also goes to `--line` stderr and `jobs.log`: only stdout and
  `--report` JSON are caller contracts.
- `hud-docs` (H9). `make check` passes; README and README.ja document
  `hud` / `icon` / the pill; this feature file covers H1-H9.
- `hud-pill` (H10). MAC_UNVERIFIED: inactive `NSPanel` with `.hudWindow`
  material, top-center of the focused screen, ok/started 1.5 s and failed
  3 s, replaced by the next fire, icon rendered per kind.

## How to get to it (user POV)

- Set a trigger rule and fire it in a text field: after the spinner a
  pill appears top-center showing e.g. `@@@ → My Rule` (or the shell
  script, or the sink name) for 1.5 s on success, 3 s on failure.
- Set `"icon": "/Applications/TextEdit.app"` (or an image path, or an
  emoji) on the rule: the pill shows that icon next to the label.
- Set top-level `"hud": false`: no pill, ever.

## Driving it with verify.sh

Preconditions: built `.build/debug/keypipe`, Linux or Mac, no daemon
needed (all H items use the fake harness). Items and evidence:

- H1. `feed H1 UP TXT @@@`: one `keypipe hud @@@ ok` line, field HELLO.
- H2. Failing transform: one `keypipe hud @@@ failed` line, the notify
  still present, field kept.
- H3a. Background output: one `keypipe hud &&& started` line.
  H3b. Terminal, nomatch, composing feeds: zero `keypipe hud` lines.
- H4a-d. Name, 40-grapheme shell truncation, newline collapse, builtin
  name plus a transform-stdout canary that must not leak into the pill.
- H5a-d. `.app` path, image path, emoji each echoed verbatim; omitted
  ends the line with bare `none`.
- H6a. `hud: false`: exit 0, matched, zero hud lines. H6b-c: unknown keys
  still rejected (guards, green before and after).
- H7a-c. Plain `--line` stdout and `--report` JSON byte-identical with
  and without the feature. H7a/c already hold and stay green (guards: the
  bridge is not a caller contract for the pill); H7b needs the `hud` key,
  so the row fails until the implement phase.
- H8. The emit shape as a protocol regex (prefix per SPEC).
- H9a. `make check-docs` (guard: SKILL.md must not name new Swift
  symbols until Sources has them). H9b-c. README / README.ja mention
  `hud` and `icon` (FAIL until the implement phase writes them).
- H10. Always SKIP with MAC_UNVERIFIED; the live-Mac pill proof is the
  manual checklist in Gotchas, not a scripted item.

In-process proof (implement phase adds it; the script cannot see it):
`EngineTests` asserting `busy == [true, false]` followed by exactly one
recorded `showFired` with the right status/label/icon, `showFired`
silence on blocked paths, and `ConfigTests` for `name` / `icon` /
`hud` parsing plus unknown-key rejection.

## Gotchas

- `make check-docs` scans README.md, README.ja.md, and
  `.claude/skills/*/SKILL.md` (not `features/`): never put a future
  Swift symbol in backticks there until Sources or Tests defines it.
  This file is the safe place for not-yet-symbols.
- The transcript label/icon fields are JSON-quoted with the existing
  `jsonString` helper; the arrow is the literal `→`.
- Truncation counts Swift `Character`s (graphemes), not UTF-8 bytes or
  UTF-16 units: an emoji counts one. Tests use ASCII plus one emoji
  case in-process.
- The 40-grapheme shell label is the raw script text, so a script with
  `$(...)` or backticks is echoed, never executed, in the label.
- Canary strings (`CANARY-9f3`) are test markers, not secrets.
- H10 manual Mac checklist: inactive panel (field keeps focus),
  top-center of the focused screen (multi-display), durations ok/started
  1.5 s failed 3 s measured, a second fire replaces the first pill, and
  each icon kind (.app, image, emoji, omitted) renders. Until then every
  claim about the visible pill is MAC_UNVERIFIED.
- Fake feeds are independent processes and can run in parallel. H10
  needs a Mac with Accessibility granted; never script clicks at the
  pill (inactive panel, no buttons).
