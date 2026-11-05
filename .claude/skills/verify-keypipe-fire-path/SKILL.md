---
name: verify-keypipe-fire-path
description: Model-check one keypipe fire (trigger match, gates, erase, transform, output), including the IME composing stop and hotkey versus text trigger. Use after touching Engine.fire, runAfterBusy, performErase, TriggerMatcher.feed, or evaluate in Sources/keypipe/Engine.swift, Trigger.swift, or Context.swift; or before claiming a Windows port preserves that contract.
---

# verify-keypipe-fire-path

TLA+ and TLC. One fire is a straight sequence with a desktop that answers in more than one way, so the question is which answers can break a promise. A model checker walks every answer in the stated bounds. The repo already model-checks the spinner and pill in verify-keypipe-hud-flow. This skill is the fire itself.

## What it promises

Each rule is one invariant. One sentence for the rule, one for the harm.

| Rule | Plain sentence | Harm when broken |
| --- | --- | --- |
| ComposingStops | While an input method is composing, the fire stops before deny, before erase, and before any shell. | Conversion in progress is deleted or sent to a command. |
| SecureStops | A password field stops the same way. | The password is erased or handed to a shell. |
| TerminalTextStops | A typed trigger in a terminal does nothing. A hotkey that does not read a field may still run. | The whole pane is read or erased. |
| UnreadableNeverFallsThrough | A fact that cannot be read stops the fire. It does not select the next rule. | A rule meant for one site runs somewhere else. |
| FrontChangedDoesNotErase | If the front changes during a slow read, nothing is erased or run. | Backspaces land in the window the user just switched to. |
| NeverShorter | If this trigger's rules do not hold, a shorter trigger is not substituted. | `@@@` failing its `when` still fires `@@`. |
| NoMatchDoesNotAct | No rule held means no erase and no shell. | A trigger is deleted and nothing replaces it. |
| HotkeyNeverBackspaces | A hotkey posts no Backspace. | The chord deletes the characters before the caret. |
| KeyAnySeesEmpty | `focus: any` on the keyboard path feeds the shell an empty input. | A rule that should not read the field sends the whole field. |
| KeyFieldSeesField | A text trigger with `focus: textField` on the keyboard path feeds the field, trigger already removed. | The transform sees the trigger, or an empty string. |
| SuppliedSeesCaller | `--line` and `--rule` pass stdin through, for either focus. | Voice or zsh text is dropped, or the field is sent instead. |
| NoInputDoesNotRun | A vanished field does not run a shell and is not a successful delivery. | A transform runs with no input, or a missing write is reported as replaced. |
| FailedTransformDoesNotDeliver | A failed transform, including its one fallback, does not deliver. | Empty or failed output wipes the field. |
| TransformFallbackOnce | `onFail.transform` runs at most once. | A fallback loops or calls itself. |
| OutputFallbackOnce | `onFail.output` runs at most once. | Same, for the sink. |
| ReplacedMeansField | Only a `textField` rule reports `replaced`. | `replaceInput` runs without a field. |
| StartedMeansSpawned | `started` is only a background spawn that did start. | voice-switch records a delivery that never launched. |
| NoFakeTypeText | `typeText` on `--line` or `--rule` does not report success. | The caller thinks text was typed into a line that has no caret. |
| NoTypeWithoutCaret | On the keyboard path, `typeText` succeeds only in a text field or a terminal. | Keys are posted at the desktop or into a password field. |
| FiredIsLongest | The trigger returned for one keystroke is the longest configured suffix of that buffer. | `ab` and `b` completing together fires `b`. |
| ResetOnFire | The matching keystroke clears the buffer. | The next character extends the trigger that already fired. |
| NoEarlyPartial | `performErase` does not hand a half-deleted trigger to the transform while reads remain. | `hello@@` is translated and written back, and the late Backspaces eat the translation. |
| HandsBody | Within 5 reads of a 3-character trigger, an app that applies one Backspace per read, and an app that ignores Backspace, both yield the body. | The 200 ms wait is not long enough for the apps the tests model. |

TLC also checks deadlock: every state can move, or it is a finished fire.

## Verification items

- V1 変換中は `keypipe composing` で止まり、消さないしシェルも走らない（ComposingStops、`testComposingDoesNotFireOrErase`）。
- V2 パスワード欄は同様（SecureStops）。
- V3 端末の文字トリガーは止まる。欄を使わないホットキーだけ通る（TerminalTextStops、`testTerminalFocusDoesNothingAtAll`）。
- V4 読めない事実は次のルールに落ちない（UnreadableNeverFallsThrough）。
- V5 遅い読取の間に前面が変わったら消さない（FrontChangedDoesNotErase）。
- V6 このトリガーの `when` が落ちても、より短いトリガーは選ばない（NeverShorter、`testNoMatchDoesNotEraseOrTryShorterTrigger`）。
- V7 ホットキーは Backspace しない。`textField` なら欄全体、`any` なら空が入力（HotkeyNeverBackspaces、KeyAnySeesEmpty、KeyFieldSeesField、`testHotkeyReadsFieldWithoutErasingAndIgnoresUnconfiguredChords`、`testAnySuppliesEmptyInputAndErasesOnlyInTextFields`）。
- V8 `--line` と `--rule` は標準入力をそのまま渡す（SuppliedSeesCaller、`testFireRuleRunsOnlyThatRuleWithTheCallersInputInEveryFocus`）。
- V9 変換の失敗（非ゼロ、期限、空出力）は配送しない。`onFail` は各段で一度だけ（FailedTransformDoesNotDeliver、TransformFallbackOnce、OutputFallbackOnce、`testEmptyTransformOutputNotifiesInsteadOfWipingField`）。
- V10 起動できなかった背景ジョブを `started` と報告しない（StartedMeansSpawned）。`--line` の `typeText` を成功と報告しない（NoFakeTypeText）。
- V11 一回の打鍵で最長の接尾辞が返り、その打鍵でバッファは空になる（FiredIsLongest、ResetOnFire）。`@@` と `@@@` が両方あると、2 文字目で `@@` が発火し `@@@` は溜まらない。
- V12 消去の読み戻しは、最初の変化では抜けない（NoEarlyPartial、HandsBody、`testEraseWaitsForEveryBackspaceBeforeReading`）。

## How to run

```sh
sh .claude/skills/verify-keypipe-fire-path/check.sh
sh .claude/skills/verify-keypipe-fire-path/mutants.sh
swift test --filter 'testComposingDoesNotFireOrErase|testNoMatchDoesNotEraseOrTryShorterTrigger|testHotkeyReadsFieldWithoutErasingAndIgnoresUnconfiguredChords|testAnySuppliesEmptyInputAndErasesOnlyInTextFields|testTerminalFocusDoesNothingAtAll|testEmptyTransformOutputNotifiesInsteadOfWipingField|testFireRuleRunsOnlyThatRuleWithTheCallersInputInEveryFocus'
```

check.sh pins TLC 1.7.4 by sha256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`. It uses mise and Java temurin-25 when mise is installed, otherwise curl and the `java` on PATH (Java 11 or later). The first mise install needs the network. Expected today: FireGates 83 states, FireStages 439, EraseReadback 10, TriggerMatch 345, all PASS, and mutants.sh catches all 16.

Read every TLC result, pass or fail, with the `/statechart` skill. It turns a violation into the shortest path in plain words and, on a pass, draws how the fire moves. The views next to the specs are gates-view.mjs, stages-view.mjs, erase-view.mjs, and trigger-view.mjs. Charts for the passing models are in `artifacts/fire-path/`.

## The model and the code it stands for

| Model action | Code (one indivisible step) |
| --- | --- |
| Feed, Hotkey, Settle | `TriggerMatcher.feed`, then `Engine.key` resets, or `Engine.hotkey` resets without a text fire |
| TerminalStop, TerminalHotkeyStop, TerminalHotkeyPass, NotTerminal | the terminal filter at the start of `Engine.fire` |
| BlockComposing, PassComposing | the composing guard in `Engine.fire`, before deny |
| BlockSecure, PassSecure | the secure guard |
| DenyMatch, DenyUnreadable, DenyClear | the deny loop |
| MatchField, MatchAny, UnreadableStops, NoMatch | the candidate loop. `evaluate` is used except in a terminal, where only fact conditions run. SelectShorter is not in Next |
| FrontMoved, FrontStable | the `readSlow` re-check |
| EraseTextField, ReadHotkeyField, EraseAnyInText, SkipEraseAny, HotkeyAny, FieldGone, FieldGoneAfterErase | the switch in `runAfterBusy` |
| BeginSync, BackgroundOk, BackgroundFail | background is decided after the input and before the sync transform |
| SkipTransform, PrimaryOk, PrimaryFailStop, PrimaryFailToFallback, FallbackOk, FallbackFail | `runTransform`. Empty, nonzero, and timeout are one failure. SecondFallback is not in Next |
| ReplaceOk, ShellOk, NotifyOk, NoneOk, TypeOk, OutputFail, OutFbOk, OutFbFail | `Engine.apply`. SecondOutputFallback is not in Next |
| Poll | one `text` read inside `performErase`'s wait |

`evaluate` also rejects composing and terminal. The engine guard runs first, so a composing fire never reaches `evaluate`. Removing only the engine guard makes the test expect `keypipe composing` and observe `keypipe nomatch`. The shell still does not run, because of `evaluate`. Shelling during composition means both checks are gone.

## Scope and assumptions

- Covered: one fire after a key or a configured hotkey, plus `--line` / `--rule` as `path = supplied`. Every focus (nothing, text, composing, terminal, secure). Rule choice between a field rule, an any rule, no match, and an unreadable fact. Deny match, deny unreadable, or deny clear. Front stable or moved after a slow read. Transform absent, ok, fail with no fallback, fallback ok, fallback fail. Output replace, shell, notify, none, typeText, background, and one output fallback. Matcher modes `aa`+`aaa`, `aaa` only, and `a`+`za`, buffer window 3. Erase behaviors `lands` and `ignores`, trigger length 3, at most 5 reads.
- Assumed: the engine queue runs one fire at a time (the hud skill covers the spinner, the pill, and the main queue). An app that applies Backspaces applies one per read and finishes inside the wait, or it ignores them entirely. `performErase` is one step in FireStages; the poll is EraseReadback. An output fallback in the model is a shell, which is the usual clipboard fallback, not a second `replaceInput`.
- Left out: a third app that delivers only one Backspace before the deadline. The code then returns that partial text. HandsBody does not claim otherwise. Also left out: `performWrite`'s own 200 ms readback, label and icon text, the detached job's later stages, URL script text, and which process is a terminal. Those stay in MacDesktop and in the unit tests.

## When a check fails

1. Run the `/statechart` skill on the failing spec to get the shortest path.
2. Replay that path against `Engine.fire` or `performErase`, one model action per branch. If the code does it, it is a bug: report the path in the code's words. Do not weaken the rule.
3. If the code does not do it, the model drifted: fix the action, rerun check.sh and mutants.sh, and update the table above.
4. An intended change (a new gate, a new sink): change the model, the tests, and this table together. mutants.sh must still catch every rule.

## Coverage record

| Check | Files and functions |
| --- | --- |
| FireGates.tla | `Engine.fire` through the `readSlow` re-check; `evaluate` |
| FireStages.tla | `runAfterBusy`, `run`, `runTransform`, `apply`; `BuiltinSink.perform` for who can fail |
| EraseReadback.tla | `performErase` |
| TriggerMatch.tla | `TriggerMatcher.feed`, `Engine.key`, `Engine.hotkey` |
| The swift test filter | the tests named under Verification items |

Sync commit: 4ee3d7629837f0c066977e90f6287d6bd7be2ee0. The specs describe that tree. This skill's own commit does not change those functions.

Confirmed on 2026-11-05 (JST): check.sh PASS with the state counts above, mutants.sh 16/16. A scratch that disabled the composing guard in `Engine.fire` failed `testComposingDoesNotFireOrErase` (`keypipe nomatch @@@` instead of `keypipe composing @@@`). The guard was restored and the test passed again.

Before moving the sync commit forward, run `git diff <sync commit> -- Sources/keypipe/Engine.swift Sources/keypipe/Trigger.swift Sources/keypipe/Context.swift Sources/keypipe/Sinks.swift`, confirm every changed line still matches the action table, then run the three commands above. Only then write the new commit here.

Bring a check that was not re-run after a covered edit back in line with `/maintain-formal-verification-skill`.
