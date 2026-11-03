---
name: verify-keypipe-rule-by-name
description: Bounded-exhaustive check of `keypipe --rule NAME` (call one rule by its name, as voice-switch does) and the command-line parse it joins, by running the real binary over every argv up to 3-4 tokens and every config of up to 2-3 rules. Covers the argv contract (exit 2 before the config), unique rule names, selection by name only (never by label), deny/when gates, stdin as KEYPIPE_INPUT for text and hotkey rules in both focus modes, and background jobs. Use when implementing --rule, after touching the parse in Sources/keypipe/main.swift, the name/label keys in Sources/keypipe/Config.swift, the candidate filter and gates in Engine.fire or the input choice in runAfterBusy (Sources/keypipe/Engine.swift); or before claiming voice-switch can call a keypipe rule by name.
---

# verify-keypipe-rule-by-name

voice-switch calls a keypipe rule by its name: `keypipe --rule grokbot` with the dictation on
stdin. The rule holds the shell once, so the keyboard (hotkey) and the voice share it. This skill
checks that promise against the real binary for every input inside the bounds below.

## Spec (decided 2026-11-03 by the operator; option 1 for a missing name)

| ID | Rule | Harm when broken |
|----|------|------------------|
| S1 | `--rule NAME` takes a value and is a mode, like `--line`. With another mode it is refused (exit 2). | A second mode is silently dropped. |
| S2 | `--app` and `--report` are accepted with `--line` or `--rule`, and refused without both (exit 2). | voice-switch cannot say which app the dictation was for. |
| S3 | `--rule ""` is refused before the config is read (exit 2), like `--line ""`. | |
| S4 | Rule names are unique. Two rules with the same `name` make the config invalid (exit 1). `label` is the display text and is never a name. | `--rule a` runs whichever rule comes first, and the user cannot tell which. |
| S5 | `--rule X` with no rule named X exits 2 after the config is read, with nothing run and nothing on stdout, also with `--report`. The stderr is not the parse's `unknown argument`. A broken config still wins (exit 1). | A typo in voice-switch's command runs another rule or looks like success. |
| S6 | `--rule X` runs only the rule named X, whether it has a `trigger` or a `hotkey`. Rules before it with the same trigger or hotkey do not run. | The dictation goes to the wrong rule. |
| S7 | A rule picked by name passes the same gates as any fire: deny, `when.app`, composing, secure. Blocked or no match: exit 2, or exit 0 with the report line under `--report`. | `--rule` becomes a way around deny. |
| S8 | The rule's input (stdin, `$1` and KEYPIPE_INPUT of transform and output.shell) is stdin byte for byte, for text and hotkey rules, with `focus: textField` and with `focus: any`, including empty stdin. | The spoken note is lost; this is the one place `--rule` differs from `--line`, where a `focus: any` rule gets empty input. |
| S9 | A background rule picked by name gets the same input in its detached job. | The grokbot rule (background) never sees the note. |

Exit codes without `--report` follow `--line`: 0 when the result `isHit`, 2 otherwise.

## Verification items (動作検証項目)

- V1 不正なコマンドラインは、設定を読む前に exit 2 と usage で止まる。`--rule` を足しても、二重指定・値の欠落・未知の引数・モードの併用・修飾子の単独使用の判定は変わらない（S1〜S3、P1）。
- V2 同じ `name` を持つルールが 2 つあれば、設定エラー（exit 1）で何も実行しない（S4、P2）。
- V3 `--rule X` は `name` が X のルールだけを実行する。`trigger` と `hotkey` のどちらのルールでも同じ。`label` が X のルールは選ばれない（S4・S6、P3）。
- V4 `--rule X` で X という名前が無いときは exit 2。何も実行せず、`--report` を付けても標準出力は空（S5、P3）。
- V5 名前で選んだルールにも deny と `when.app` が効く。ブロックや不一致は exit 2、`--report` 付きなら blocked または nomatch の 1 行で exit 0（S7、P4）。
- V6 名前で選んだルールのシェルには、標準入力がそのまま KEYPIPE_INPUT として届く。text と hotkey、`focus: textField` と `focus: any` の 4 通りすべてで、空の入力・引用符・`$(…)`・改行・日本語を含めて同じ（S8、P5）。
- V7 バックグラウンドのルールを名前で呼んでも、切り離したジョブに標準入力が届く（S9、P6）。
- V8 ピルや履歴の表示文字列は、`label`、無ければ `name`、無ければ出力のシェルの順で決まる（形式検査の対象外。`HudTests` の `firedLabel` テストで確かめる。`testLabelPrefersLabelThenNameThenScriptThenSinkAndCollapsesWhitespace` と `testLabelsMayRepeatAndShareANameButNamesMayNot`）。

## How to run

```sh
bash .claude/skills/verify-keypipe-rule-by-name/check.sh            # exit 0 = every property PASS (~400 argv + ~300 config runs)
DEEP=1 bash .claude/skills/verify-keypipe-rule-by-name/check.sh     # 4-token argv, 3-rule configs; ~10x the runs
```

check.sh is manual. `make check` runs only the in-process half: `EngineTests`
testFireRuleRunsOnlyThatRuleWithTheCallersInputInEveryFocus (S6, S8) and
testFireRuleStopsAtDenyAndHandsTheInputToABackgroundJob (S7, S9).

It builds with `swift build` and runs `.build/debug/keypipe`. No Mac permissions are needed: the
`--rule` path reads no real field, and every case passes `--app` or needs no app.

Each rule's output.shell appends `R<index>[<KEYPIPE_INPUT>]` to `$KP_OUT`, so the file shows
which rules ran and with what input. P1 passes `--config` with a file that does not exist: a
refusal must come first (exit 2 with `usage:`), and anything the parse lets through then fails to
read the config (exit 1).

## Bounds and what is not covered

- P1: every argv of 0 to 3 tokens (4 with DEEP) over `--rule --line --app --report --triggers
  --feed-stdin g ''`, after `--config <missing>`. Values that equal a flag name are inside this
  alphabet (the `--line --config` case of 2e33ff3). `--job`, `--probe`, `--smoke-*`, `--context`
  and `--help` are not in it: `--job` and `--probe` run before the config is read.
- P2/P3: every config of 1 to 2 rules (3 with DEEP), each rule one of
  {`trigger` @@@, `hotkey` ctrl+cmd+g} × {no name, name a, name b, label a}, asked for a, b and c.
- P4-P6: the fixed cases in check.sh.
- Not covered: the terminal gate (the `--rule` desktop is never a terminal), composing and secure
  (the line desktop never reports them), `onFail`, transform stages, `replaceInput` stdout, the live
  daemon, and voice-switch itself. The label text is covered by `HudTests`, not here.

## Reading a failure

Each property prints one FAIL line with the first counterexample: the argv or config, what the
binary did (exit, which rules ran, stdout), and what the spec wants.

- A real bug: the counterexample breaks a row of the Spec table above. Fix the product code.
- A modeling error: the counterexample is something the operator wants. Then the Spec table and the
  oracle in check.sh (`spec_refuses`, the expectations in P3-P6) change together, in the same
  commit, with the operator's approval. Never loosen the oracle only to get a PASS.

## Prove it catches breaks

Make each scratch edit in the real code, run check.sh, see the named property FAIL, then
`git checkout` the file. Done only when every row fails as listed and the clean tree passes.

| Scratch edit | Must fail |
|--------------|-----------|
| Drop the duplicate-name check in Config.swift | P2 |
| Leave `--rule` out of `modes` in main.swift (`--rule g --line g` gets through) | P1 |
| Keep `--app`/`--report` limited to `--line` | P1 (and P4) |
| Pick the rule by `label` as well as `name` | P3 |
| Run the first rule with the same trigger instead of the named one | P3 |
| Skip the deny loop for `--rule` | P4 |
| Keep `input = ""` for `focus: any` under `--rule` (the `runAfterBusy` switch) | P5 |
| Drop the input from the background Job for `--rule` | P6 |

## Coverage and sync

| Check | Code it describes |
|-------|-------------------|
| P1 | Sources/keypipe/main.swift: the single parse closure (`takesValue`, `alone`, the modifier loop, the empty-value checks, `modes`) |
| P2 | Sources/keypipe/Config.swift: the rule keys list, the `name`/`label` reads, and the duplicate-name loop after the rules are built |
| P3 | main.swift: the `--rule` branch (the one name lookup, `firstIndex`); Sources/keypipe/Engine.swift: fire(rule:input:), which runs only that index |
| P4 | Engine.swift: the gates in `Engine.fire` (deny loop, `when` evaluation), shared by both entry points |
| P5 | Engine.swift: the input choice in `runAfterBusy`, and the line desktop `--rule` builds in main.swift. That line still ends with a text rule's trigger, so the erase succeeds; without it a `focus: textField` text rule is noInput |
| P6 | Engine.swift: the background `Job` input; Sources/keypipe/Shell.swift and `startJob` |

- Sync commit: **作業ツリー（feat/rule-by-name、未コミット）で確認済み** (2026-11-03).
  check.sh and DEEP=1 pass, and each of the eight scratch edits above fails its listed property.
  Replace this line with the commit hash once the change is committed.
- Move the sync commit forward only after confirming that the Spec table and the oracle still
  describe the code at the new commit. If any file in the Coverage table changed after the sync
  commit, reread its part before trusting a PASS.
- A change to an exit code or to S5 updates README.md, README.ja.md and
  docs/design/context-rules.md in the same commit (CLAUDE.md rule table).
