---
name: verify-keypipe-herdr-claude
description: Verify the keypipe rule that sends the selected text to Claude Code in a new Herdr tab, from a hotkey (selection only) and from voice-switch (`keypipe --rule herdr-claude`, dictation plus selection), implemented by shell/herdr-claude.sh. Covers the prompt shape, byte-exact delivery through `herdr agent prompt`, clipboard restore, empty input, Herdr failing, no login PATH, and the live hotkey and voice runs on a Mac. Use after touching shell/herdr-claude.sh or the herdr-claude rule, or before claiming the selection or the voice reaches Claude Code in Herdr.
---

# verify-keypipe-herdr-claude

Goal. Select text in any app, press one hotkey, and a new Herdr tab opens with Claude Code
already working on that text. From voice-switch, say an instruction, and the instruction plus the
selection go to Claude Code in a new Herdr tab.

## Setup

keypipe rule (`~/.config/keypipe/config.json`):

```json
{ "name": "herdr-claude", "label": "Claude Code (Herdr)", "hotkey": "ctrl+alt+cmd+j", "when": { "focus": "any" },
  "icon": "/Applications/Claude.app",
  "output": { "shell": "HERDR_BIN=$HOME/.local/bin/herdr $HOME/repos/keypipe/shell/herdr-claude.sh", "background": true } }
```

voice-switch action (`~/.config/voice-switch/config.json`, `macOS.actions`):

```json
{ "name": "herdr-claude", "wakeWords": ["クロード", "claude"],
  "command": "<absolute keypipe> --rule herdr-claude ${VOICE_SWITCH_APP:+--app \"$VOICE_SWITCH_APP\"}",
  "superwhisperMode": "input-voice-switch", "icon": "/Applications/Claude.app" }
```

On the operator's Mac, Karabiner turns the physical left ctrl into ctrl+cmd+option, so the user
presses ctrl+j (or ctrl+cmd+j) and keypipe sees ctrl+alt+cmd+j. ctrl+alt+cmd+h was tried first and
failed: Alter owns that chord, comes to the front, and the script's Cmd+C copies nothing (exit 3).
System Events keystrokes skip Karabiner, so a hotkey that passes through System Events can still
fail on the real keyboard. Pick the chord from what Karabiner sends, then check that the front app
stays the same after it.

`HERDR_CLAUDE_CWD` in the rule's shell sets the new tab's directory. Left out, the tab opens in
the focused Herdr workspace's directory.

## Herdr surface (observed 2026-11-03)

- `herdr tab create --focus --label L [--cwd P]` prints JSON with `.result.root_pane.pane_id`.
- The new pane's shell takes a moment to start. Until then `agent start` fails with
  `agent_pane_busy`, so the script retries for up to 10 s.
- `herdr agent start NAME --kind claude --pane ID` returns once Claude Code is ready. NAME allows
  only `[a-z0-9_-]`, up to 32 characters. In a folder Claude Code does not trust yet, Claude stops at
  its trust prompt and `agent start` fails with `agent_not_ready`. The home directory was such a
  folder, so the script does not default to it.
- `herdr agent prompt ID TEXT` submits TEXT as one argument, with no shell in between.
- `herdr pane run ID CMD` types into the shell, so a selection with newlines would run line by line.
  The script never uses it.

## Data shape

| Input | Hotkey | voice-switch |
|-------|--------|--------------|
| selection | a synthetic Cmd+C in the front app, then the old clipboard is put back | the same, after `open -b $VOICE_SWITCH_APP` |
| dictation | empty (`focus: any` gets empty input) | stdin, so `KEYPIPE_INPUT` |

prompt = dictation empty ? selection : selection empty ? dictation : dictation + "\n\n" + selection.
Both empty means no tab. This is the same capture and order as the `grokbot` rule in the operator's
config, which was already in daily use.

## Spec

| ID | Rule | Harm when broken |
|----|------|------------------|
| S1 | One rule with a `name`, a `hotkey`, `focus: any`, and a background `output.shell`. The keyboard and voice-switch share it. | Two copies of the shell drift apart. |
| S2 | A fire opens exactly one new Herdr tab, starts Claude Code in it, and submits the prompt there. | The text lands in someone else's session. |
| S3 | The prompt reaches Claude Code byte for byte: newlines, quotes, `$HOME`, backquotes, `$(...)`, Japanese, about 2 KB. No shell runs on the way. The clipboard is restored afterwards. | A selection runs as commands; the user's clipboard is lost. |
| S4 | Prompt shape as in the Data shape section. | Claude reads the instruction as part of the material. |
| S5 | Empty selection and empty dictation: no tab, exit 3, keypipe notifies. | An empty Claude tab per stray key press. |
| S6 | Any herdr step failing: exit 1 and the whole prompt is left on the clipboard. keypipe's `onFail.output` would get only the dictation, so the script does this itself. | The dictated instruction is lost. |
| S7 | Works without the login `PATH` (the daemon's `/bin/sh -c`, voice-switch's launchd). The herdr path comes from `HERDR_BIN` in the config; no user path in the repo. | Works from a terminal, fails from the daemon or the microphone. |
| S8 | `background: true`. Starting Claude takes about 5 s, and voice-switch must not wait for it. | voice-switch hangs, or a slow start is killed at `shellTimeout`. |

## Verification items (動作検証項目)

- V1 ルールの設定が読める（S1）。
- V2 `keypipe --rule herdr-claude --report` が `started` を返し、ジョブが herdr に `tab create`、`agent start`、`agent prompt` の順で頼む。実機では新しいタブがちょうど 1 つ増える（S2・S8）。
- V3 改行・引用符・`$HOME`・バッククォート・`$(...)`・日本語・約 2 KB の選択が、`agent prompt` の TEXT 引数にバイト一致で届き、`pane run` は呼ばれない。終わったあとクリップボードが元に戻る（S3）。
- V4 選択も音声も空なら、herdr を呼ばず exit 3、クリップボードはそのまま（S5）。
- V5 `tab create` が失敗すると exit 1 で、プロンプト全体がクリップボードに残る（S6）。
- V6 `env -i` でログインシェルの `PATH` を外しても V2 が通る。スクリプトに `/Users/` が無い（S7）。
- V7 実機で、新しいタブの Claude Code が起動して入力を受け付ける（`LIVE=1`）。
- V8 実機。TextEdit や CotEditor で文字を選び、実物のキーボードで ctrl+j を押す（Karabiner により ctrl+alt+cmd+j になる）。押した直後も前面のアプリが変わらず、Herdr に新しいタブが開き、Claude Code がその文字を受け取って動き出す。
- V9 音声、空行、選択の順にプロンプトが組まれる（S4）。
- V10 選択が空なら、音声だけがプロンプトになる（S4）。
- V11 `VOICE_SWITCH_APP` があれば、コピーの前にそのアプリを前に出す。
- V12 実機。文字を選び、voice-switch でウェイクワード「クロード」と指示を話す。Herdr に新しいタブが開き、指示と選択を受け取った Claude Code が動き出す。

## How to run

```sh
swift build
bash .claude/skills/verify-keypipe-herdr-claude/check.sh           # V1-V6, V9-V11 against stubs
LIVE=1 bash .claude/skills/verify-keypipe-herdr-claude/check.sh    # adds V7: real Herdr and Claude Code, closes its tab
```

The stubs replace herdr, `pbcopy`, `pbpaste`, `osascript` (its Cmd+C copies a fixed selection) and
`open`, so check.sh never touches the real clipboard or keyboard. V8 and V12 are manual. V8 can
also be driven with System Events: make a TextEdit document, select all, then
`keystroke "h" using {control down, command down}`.

## Results

2026-11-03, working tree on main (uncommitted):

- check.sh with `LIVE=1`: ALL PASS.
- Swapping dictation and selection in the script fails V5, V9 and V6. Checked, then reverted.
- V8 through System Events with the live daemon: Claude Code in the new tab quoted the TextEdit line back.
- V8 on the real keyboard (operator, CotEditor, left ctrl+j): the daemon logged
  `matched ctrl+alt+cmd+j` and the job exited 0. Pressing ctrl+option+j instead typed `∆`.
- V12 without the microphone: `printf '<instruction>' | VOICE_SWITCH_APP=com.apple.TextEdit keypipe --rule herdr-claude --app com.apple.TextEdit`
  gave `started`, and Claude Code got the instruction, a blank line, then the TextEdit selection.
  Wake-word recognition by voice-switch itself is not checked yet.

Not covered: Herdr UI not running at all, a second fire before the first tab is ready, and apps
where Cmd+C copies nothing (the prompt is then the dictation alone, or nothing).
