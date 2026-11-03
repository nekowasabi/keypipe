---
name: verify-keypipe-hud-flow
description: Model-check keypipe's fire-to-HUD flow (busy spinner and fired pill) with TLA+/TLC over every interleaving of the engine queue, the main queue and the pill's hide timer, for up to 3 fires, with hud on and off. Use after touching Engine.fire, runAfterBusy or showFiredIfNeeded in Sources/keypipe/Engine.swift, showBusy/hideBusy/showFired or BusySpinner/FiredHUD in Sources/keypipe/MacDesktop.swift, the engine queue in Sources/keypipe/main.swift, or the Desktop protocol's HUD calls; or before claiming the spinner and pill appear and disappear correctly.
---

# verify-keypipe-hud-flow

## What it promises (the rules)

Each rule is an invariant in HudFlow.tla. One sentence for the rule, one for the harm.

| Rule | Plain sentence | Harm when broken |
|------|----------------|------------------|
| GatedFireShowsNothing | A fire stopped at a gate (terminal, composing, secure, deny, unreadable, noMatch, front-changed) shows neither the spinner nor a pill. | The user sees "working" or "done" for something that never ran. |
| SpinnerGoneBeforeItsPill | A fire's pill is never on screen together with that fire's spinner. | "Done" and "still working" show at once. |
| OnePillPerFinishedFire | A fire shows at most one pill, and only for ok, failed or started with `hud` on; noInput shows none. | Duplicate or bogus pills; `hud: false` ignored. |
| NoStaleHide | A pill disappears only by its own timer or by being replaced; an older fire's timer never hides it early. | The second fire's pill flashes for a moment. |
| SpinnerGoneAtRest | Once the engine is idle and the main queue has run, the spinner is hidden. | A spinner stuck on screen forever. |
| PillGoneAtRest | Once no hide timer is left either, the pill is hidden. | A pill stuck on screen forever. |

TLC also checks for deadlock (every state can move or is a finished run).

## Verification items (動作検証項目)

- V1 発火してゲートで止まったときは、スピナーもピルも出ない（GatedFireShowsNothing、`HudFlowConformanceTests.testGatedFirePostsNothing`）。
- V2 規則が一致したら、処理の前にスピナーを出すよう依頼する（model: PostSpinner、テスト全件の先頭が `spin`）。
- V3 処理中はスピナーだけが出ていて、その発火のピルは出ていない（SpinnerGoneBeforeItsPill）。
- V4 処理が終わったら、まずスピナーを消し、その後で成功・失敗・バックグラウンド開始のピルを 1 回だけ出す（OnePillPerFinishedFire、`testOkPostsSpinHideThenPill`、`testFailedPostsSpinHideThenPill`、`testStartedAndFailedSpawnPostSpinHideThenPill`）。
- V5 入力欄が消えた（noInput）ときは、スピナーを消すだけでピルは出さない（`testNoInputPostsSpinAndHideOnly`）。
- V6 `hud: false` ではピルを出さず、スピナーは今までどおり出して消す（HudFlowOff.cfg、`testHudOffPostsSpinAndHideOnly`）。
- V7 ピルは 1.5 秒（失敗は 3 秒）で消え、次の発火のピルが来たら置き換わる。古いタイマーが新しいピルを消さない（NoStaleHide）。
- V8 すべて終わったら、スピナーもピルも画面に残らない（SpinnerGoneAtRest、PillGoneAtRest）。

## How to run

```sh
sh .claude/skills/verify-keypipe-hud-flow/check.sh      # both configs; ~2 s; exit 0 = PASS
sh .claude/skills/verify-keypipe-hud-flow/mutants.sh    # each rule fails on a broken model; exit 0 = all caught
swift test --filter HudFlowConformanceTests             # the code posts what the model posts
```

check.sh pins TLC 1.7.4 (tla2tools.jar by sha256) and Java temurin-25 through mise, the same pins
the `/statechart` skill uses. The first run needs the network. Expected today:
HudFlow.cfg 6630 distinct states PASS, HudFlowOff.cfg 2556 distinct states PASS, all 6 mutants caught.

Read every TLC result, pass or fail, with the `/statechart` skill: give it HudFlow.tla, a config
and view.mjs as the view. It turns a violation into the shortest path in plain words and, on a
pass, draws the chart. Use HudFlowChart.cfg (one fire) for a readable chart; HudFlow.cfg (three
fires) is past the chart's state budget.

## The model and the code it stands for

Two serial queues and one timer, exactly as the code runs on a Mac:

- engine queue `keypipe.engine` (main.swift): runs `Engine.fire` one fire at a time;
- main queue (AppKit): runs the blocks `MacDesktop` posts with `DispatchQueue.main.async`, FIFO;
- the pill's `asyncAfter` hide work item (`FiredHUD.show`).

| Model action | Code (one indivisible step) |
|---|---|
| TriggerTyped | MacKeyTap posts to the engine queue; `Engine.key` / `Engine.hotkey` call `Engine.fire` |
| GateStops | every `return` in `Engine.fire` before `desktop.showBusy` |
| GatePasses | `hits += 1`, "keypipe matched" |
| PostSpinner | `MacDesktop.showBusy`: posts `BusySpinner.show` to main |
| RunEnds(o) | `runAfterBusy` returns ok (replaced/delivered), failed, started, or noInput |
| PostHide | `MacDesktop.hideBusy`: posts `BusySpinner.hide` to main |
| PostPill | `showFiredIfNeeded` -> `MacDesktop.showFired`: posts `FiredHUD.show` unless `hud` is false or the result is not ok/failed/started |
| MainShowsSpinner / MainHidesSpinner | `BusySpinner.show(at:)` / `BusySpinner.hide()` on main |
| MainShowsPill | `FiredHUD.show`: `hideWork?.cancel()`, replace the panel, schedule a new hide item |
| HideTimerFires(i) | the asyncAfter item runs on main; cancelled items do nothing, live ones order out the current panel |

`HudFlowConformanceTests` (with `FakeDesktop.windows`) pins the engine half: for each way a fire
ends, the engine calls showBusy, hideBusy, showFired in exactly the order the model posts them.
The main-queue half (`FiredHUD`, `BusySpinner`) is AppKit and has no swift test; when it changes,
re-read it against the MainShows*/HideTimerFires actions by hand.

## Scope and assumptions

- Covered: order and pairing of spinner and pill across up to 3 fires, every interleaving of
  the engine queue, the main queue and the hide timers, `hud` true and false.
- Assumed: DispatchQueue.main runs blocks FIFO and one at a time; the engine queue is serial;
  a `DispatchWorkItem` cancelled on main before it runs does nothing.
- Left out: durations (1.5 s / 3 s are any delay here), placement, icon drawing, label text
  (HudTests and features/hud.md H10-H14), notifications, the detached `--job` (it never draws),
  `--line` and jobs (their Desktop draws nothing).

## When a check fails

1. Run the `/statechart` skill on the failing config to get the shortest path.
2. Replay the path against the code with `FakeDesktop` (engine half) or by reading `FiredHUD` /
   `BusySpinner` (main half). If the code really does it, it is a bug: report the path in the
   code's words, do not weaken the rule.
3. If the code does not do it, the model drifted from the code: fix the action that differs,
   rerun check.sh and mutants.sh, and update the table above.
4. An intended behavior change (for example, a new outcome that shows a pill): change the model,
   the conformance tests and the rules table together, then confirm mutants.sh still catches all.

## Coverage record

| Check | Files and functions |
|---|---|
| HudFlow.tla engine actions | Engine.swift `Engine.fire`, `runAfterBusy`, `showFiredIfNeeded`; main.swift engine queue |
| HudFlow.tla main actions | MacDesktop.swift `showBusy`, `hideBusy`, `showFired`, `BusySpinner`, `FiredHUD` |
| HudFlowConformanceTests | Engine.swift as above; FakeDesktop.swift `showBusy`, `hideBusy`, `showFired`, `windows` |

Sync commit: 3659b4af4918bb5cf8d5c8a9167bd8cea1f09af7 (feat/fired-hud, PR #5) plus the
commit on fix/fired-hud-findings that adds this skill, the FakeDesktop `windows` log and
HudFlowConformanceTests. The H11-H14 fix commit before it did not touch the modeled flow.
Confirmed on 2026-11-03: check.sh PASS, mutants.sh 6/6 caught, conformance 6/6 pass, and a scratch
`defer { desktop.hideBusy() }` in `Engine.fire` failed 4 conformance tests (HudTests missed it).

Before moving the sync commit forward, run
`git diff <sync commit> -- Sources/keypipe/Engine.swift Sources/keypipe/MacDesktop.swift Sources/keypipe/main.swift Sources/keypipe/FakeDesktop.swift`,
confirm every changed line still matches the action table, then run the three commands above.
Only then write the new commit here.
