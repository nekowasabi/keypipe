# keypipe

[English](README.md) | 日本語

keypipe は Espanso に似た Mac のバックグラウンドデーモンです。テキスト欄で
`@@@` のようなトリガーを打つと、欄の文字を設定した変換（任意のシェルコマンド。
スクリプト、`claude -p`、`curl`）に通し、結果を設定した送り先（欄の置換、または
tmux、webhook、クリップボードなど任意のシェルコマンド）へ渡します。メニューバー
UI は意図的にありません。設定は 1 つの JSON ファイルです。設計は
`docs/design/context-rules.md` にあります。

## 必要条件

- macOS 13 以降、Xcode 15 または Swift 5.9 ツールチェーン。
- Linux ビルドでは偽のデスクトップ（`--context` と `--feed-stdin` か
  `--smoke-feed`）に対してパイプライン全体を動かせます。これが単体テストの経路です。
  実際のキー取得と Accessibility は macOS 専用です。

## ビルド

```sh
swift build
```

## 実行

```sh
mkdir -p ~/.config/keypipe && cp config.example.json ~/.config/keypipe/config.json
make            # 起動中のデーモンを止め、swift build し、起動し直す
make status     # pid と直近のログ
make stop
# または手で任意のファイルを指す
.build/debug/keypipe --config /path/to/keypipe.json &
```

`make`（`dev` ターゲット）が動作確認の最短手順で、`make stop`、`make build`、
`make start` を順に行います。`start` は `nohup` でデーモンを起動し、stdout と
stderr を `~/.local/state/keypipe/keypipe.log`（`LOG=` で変更可）に書き、5 秒以内に
`keypipe started` が出なければ失敗します。`CONFIG=/path.json` で `--config` を
渡せます。`make log` でログを追い、`make test` と `make verify` が単体テストと
検証スキルです（`VERIFY_ARGS=--no-live` で実機項目を飛ばします）。

起動時にデーモンはルール数と設定パスとともに `keypipe started` を出力します。
SIGINT（Ctrl-C）または SIGTERM（`kill -TERM`）まで動作し続けます。

キー取得が無い環境では、打鍵とデスクトップの状態を明示的に渡します。
`--context` に偽デスクトップの JSON を指定し、打ったキーはその `fieldText` の
末尾に足されます。

```sh
cat > /tmp/ctx.json <<'EOF'
{"app":"com.apple.TextEdit","focusIsTextField":true,"fieldText":"hello"}
EOF
# 文字列を 1 つ流し、一致したルールを発火し、最終的な欄の文字を出す。
.build/debug/keypipe --config ./config.example.json --context /tmp/ctx.json --smoke-feed '@@@'
# EOF まで stdin を流す。
echo '@@@' | .build/debug/keypipe --config ./config.example.json --context /tmp/ctx.json --feed-stdin
```

一致するとデーモンは `keypipe matched <trigger> rule <n>` を出し、段ごとに 1 行
（`erase`、`transform exit`、`apply` か `output-shell exit`）、最後に偽の欄の文字を
`keypipe field <json>` で出します。`--smoke-feed` はルールが一致すれば終了コード 0、
どれも一致しなければ 2 です。出力行の契約は
`.claude/skills/verify-keypipe-rules/SKILL.md` にあります。

## 設定

1 つの JSON ファイル（MVP では `"json"` 形式のみ受け付けます。TOML と YAML は
対象外です）。パスは `--config` で渡し、既定値は
`$XDG_CONFIG_HOME/keypipe/config.json`（変数が無ければ
`~/.config/keypipe/config.json`）です。`--config` 無しでファイルが無いと
終了コード 1 でそのパスを案内します。まず `config.example.json` をそこへ
コピーして開始してください。

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "when": { "app": ["com.apple.TextEdit"], "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput"
    },
    {
      "trigger": ";;;",
      "when": { "focus": "textField" },
      "output": { "shell": "tmux send-keys -t work:claude -l -- \"$1\"" }
    }
  ]
}
```

- `trigger` は直近のキー入力の末尾に一致する空でない文字列で、最大 64 文字です。
  複数のルールが同じバッファに一致したら最長のトリガーが勝ちます。同じトリガーの
  ルールは、設定順で最初に `when` を満たすものが勝ちます。どれも満たさなければ
  何もしません（短いトリガーへは落ちません）。
- `hotkey` は `trigger` の代わりに書くキーの組み合わせです（ルールにはどちらか一つ）。
  `"ctrl+@"` や `"alt+cmd+x"` のように書きます。修飾キーは `ctrl`/`control`、
  `alt`/`option`、`cmd`/`command` で、最低一つ必要です。shift は修飾キーではなく
  文字側に含めます（ctrl+shift+a は `"ctrl+A"`）。文字は現在のキーボード配列が
  生む文字です（JIS なら `ctrl+@` は `@` キー、US なら shift+2）。ホットキーは
  何も消しません。`focus: textField` なら欄の全文が入力、`any` なら入力は空です。
  どのルールにも無い組み合わせ（Cmd+C、Cmd+Tab）は行を出さずに無視します。
  tap は listen-only なので前面アプリも必ず同じキーを受け取り、アプリがそのキーを
  束縛しているかを keypipe は判別できません。アプリが `ctrl+@` を持っているなら
  `when.app` で発火先を絞ってください。絞らなければ両方が動きます。
- `when.url` は、前面のブラウザのタブの URL に対するグロブの一覧です（Chrome、Arc、
  Brave、Edge、Vivaldi、Safari。`osascript` で読むので、macOS がブラウザの操作の
  許可を一度だけ求めます）。URL は、ルールの安い条件（`app`、`focus`）が満たされた
  ときだけ、1 回の発火につき最大 1 回読みます。ブラウザが前面なのに URL を読めない
  とき（許可が無い、1 秒の期限切れ）は、同じトリガーの次のルールへ進まず、通知して
  止まります。ブラウザ以外のアプリと `--line` の経路（zsh、音声）では、`url` は単に
  一致しません。URL を読むあいだに前面アプリが変わったら、何も消さず何も走らせません
  （`keypipe front-changed`）。
- 事実の条件（`app`、`url`）はどれもグロブの一覧です（`fnmatch`。`*` は `/` も
  またぎます）。`"app": ["com.apple.*"]` と書け、そのままの id は完全一致のままです。
  空の一覧は何にも一致しないので、`invalid config: empty url list` のように拒否します。
- `deny`（トップレベル）は、`focus` を除いた `when` と同じ形のオブジェクトの一覧です
  （例: `{"app": ["com.1password.1password"]}`）。どれかが満たされると、keypipe は
  ルールも欄の読み取りも行う前に止まります（`keypipe deny`）。`url` を書く項目には
  `app` も要ります。別のアプリが前面のときに、キー入力のトリガーがブラウザへ問い
  合わせないためです。`deny` の `url` が読めないときも止まります。`--line` の経路
  （zsh、音声）では事実をその場で読まないので、`url` を書いた `deny` の項目は一致せず、
  その発火を止めません。
- パスワード欄（`AXSecureTextField`）では何もしません（`keypipe secure`）。消さず、
  読まず、シェルも走らせません。
- `when.app` は bundle id の一覧（省略で全アプリ）。`when.focus` は `textField` か
  `any`（既定）。`textField` のルールはテキスト要素にフォーカスがあるときだけ
  発火し、トリガーを消して欄を読み、それが入力になります。`any` のルールはどこでも
  発火し入力は空文字で、テキスト要素ならトリガーだけ消します。IME の変換中は
  何も発火しません。
- `transform` は省略可で、`/bin/sh -c` で走るシェルコマンドです。入力は stdin、
  `$1`、`KEYPIPE_INPUT` で受け、前面アプリは `KEYPIPE_APP` です。stdout から末尾の
  改行を 1 つ落としたものが結果です。非ゼロ終了、期限切れ（`shellTimeout`）、空の
  出力は失敗です。`onFail.transform` があればそれを走らせ、無ければ何も送らず
  理由を通知します。
- `output` は `"replaceInput"`（同じ欄に結果を書き戻す。`focus: textField` が必要）、
  `"typeText"`（キャレットの位置に結果をキーイベントで打つ。keypipe 自身の tap は
  このイベントを無視する。`--line` にはキャレットが無いので `unsupported` で失敗。変換のあいだに前面の
  アプリ・フォーカス・欄が変わったら何も打たず `gone` で失敗）、
  `"notify"`、`"none"`（既定）、または `{ "shell": "..." }`（変換と同じ経路で結果を
  受ける）。クリップボードは `{ "shell": "pbcopy" }`、webhook は `curl` で書きます。
  `{ "shell": "...", "background": true }` はすぐ戻ります。切り離したジョブ（独自の
  セッションなので端末を閉じても止まらない）が変換・シェル・`onFail` を走らせ、記録を
  `${XDG_STATE_HOME:-~/.local/state}/keypipe/jobs.log` に追記し、失敗したら通知します。
  `background` は主の `output.shell` にだけ書けます。
- `onFail` は段ごとの代替で、その段と同じ書き方です。
  `"onFail": { "transform": "curl ...", "output": { "shell": "pbcopy" } }`。
  `onFail.transform` は `transform` が非ゼロ終了、期限切れ、空出力のとき同じ入力で
  一度だけ走り、その stdout が `output` へ進みます。`onFail.output` は `output` が
  失敗したとき同じ結果で一度だけ走ります。失敗とは `output.shell` の非ゼロか期限切れ、
  `replaceInput` の書き込みが反映されない（`ignored`）か変換中に欄が消えた（`gone`）
  ことです。代替のシェルは理由を `KEYPIPE_FAILURE`（`exit <n>` / `timeout` / `empty` /
  `ignored` / `gone` / `unsupported`）で受けます。代替の代替はありません。代替も失敗したら通知します。
  `onFail` が無いときは、`replaceInput` の失敗は結果を通知して文字を失わず、
  `output.shell` の失敗は記録だけです。同じコマンドの言い換えはシェルの `||` で
  書き、別の行き先へ逃がすときやシェルから見えない失敗を拾うときに `onFail` を使います。
- `shellTimeout`（最上位、秒、既定 30）は keypipe が走らせる全シェルの期限です。
  過ぎたらプロセスグループごと止めます。
- `backgroundTimeout`（最上位、秒、既定 300）は裏のジョブ全体の期限です。達したら
  失敗です（`output-shell timeout <n>`）。
- 未知のキー、空の `trigger` / `transform` / `output.shell`、未知の `output` や
  `focus`、`focus: textField` の無い `replaceInput`、`transform` の無い
  `onFail.transform`、失敗しない送り先（`none`、`notify`）への `onFail.output`、
  代替への `background`、`replaceInput` へ逃がす裏の送り先、正でない `shellTimeout`
  や `backgroundTimeout` は読み込み時に `invalid config: <理由>` で拒否し、
  終了コード 1 です。

## ターミナル（zsh）

ターミナルは画面全体を一つの AX テキスト欄として見せるので、前面アプリが pty の
マスター（`/dev/ptmx`）を持つときデーモンは何もしません。消さず、読まず、シェルも
走らせません（`keypipe terminal <trigger>`）。例外は `focus: any` の `hotkey`
ルールだけです。欄を読まないので、空の入力のまま動きます（ペインの要約や通知など）。
zsh のプロンプトでは ZLE ウィジェットが同じ JSON のルールを入力中の行に適用します。

```sh
# .zshrc
export KEYPIPE_BIN=~/repos/keypipe/.build/debug/keypipe KEYPIPE_CONFIG=~/.config/keypipe/config.json
source ~/repos/keypipe/shell/keypipe.zsh   # 任意: KEYPIPE_APP=<bundle id>
```

ウィジェットは単発のフラグを二つ呼びます。`keypipe --config C --triggers` は文字の
トリガーを 1 行に 1 つずつ重複なく出します。`keypipe --config C --line <trigger>
[--app <bundle id>]` は stdin でトリガーを除いた行を受け、そのアプリ（既定は前面
アプリ）のフォーカスされたテキスト欄としてルールを走らせ、新しい行を stdout に
出します。`replaceInput` なら結果、それ以外は行をそのままです。終了コードは一致 0、
ルール無し・ゲート（deny）で止まった・引数の不正は 2（ウィジェットはトリガーを残す）、
設定不正 1 です。記録は stderr に出ます。

`--report` を付けると、新しい行の代わりに、発火の結果を JSON 1 行で出します（終了
コードは書けたら 0、設定不正なら 1、引数の不正なら 2）。`outcome` は `replaced`・`delivered`・
`started`・`failed`・`nomatch`・`blocked`・`unreadable`・`noinput` のどれかです。
voice-switch の `keypipe` 配送はこれを読み、`replaced` のときだけ結果を貼ります。
全種類の例は `Tests/keypipeTests/Fixtures/report-v1.jsonl` にあります。

対応するシェルは zsh だけです。ウィジェットは ZLE のコードなので、bash や fish
などではターミナルでルールが動きません。ターミナル内の全画面プログラム（nvim、
less、REPL）でも動きません。他のシェルで使うには、同じ `--triggers` と `--line`
を呼ぶ小さなウィジェットがシェルごとに要ります（bash は `bind -x` と
`READLINE_LINE`、fish は `commandline`）。いまは同梱していません。

`KEYPIPE_BIN` はウィジェットが呼ぶバイナリを指すだけで、デバッグ版とリリース版で
動作は変わりません。デーモンと同じビルド（たとえば `PATH` に入れたリリース版）を
指してください。古いビルドを指したままだと、新しいビルドで足した設定キーを拒否する
ことがあります。`KEYPIPE_BIN` が実行できないか、設定を読めないか設定が不正なとき、
ウィジェットは何もせず、何も表示しません。理由は `keypipe --config C --triggers` で
確かめられます。

## 音声（voice-switch）

同じ `--line` を使って、[voice-switch](https://github.com/nekowasabi/voice-switch) から
音声入力の内容をルールに流せます。ひとつのルールがキーボードとマイクの両方に効きます。
voice-switch の `command` アクションは、書き起こした文章を標準入力（末尾の改行なし）で、
入力の宛先だったアプリの bundle id を `VOICE_SWITCH_APP` で渡してシェルコマンドを動かします。

```json
{
  "name": "keypipe",
  "wakeWords": ["キーパイプ"],
  "command": "/usr/local/bin/keypipe --config ~/.config/keypipe/config.json --line @@@ ${VOICE_SWITCH_APP:+--app \"$VOICE_SWITCH_APP\"}",
  "superwhisperMode": "voice_switch"
}
```

keypipe は zsh ウィジェットのときと同じく、その文章をそのアプリのフォーカスされた
テキスト欄の行として扱います。キーボードと違う点は次のとおりです。

- 動くのは `trigger` ルールだけで、`hotkey` ルールは動きません。
- 文章を受け取るルールには `"when": {"focus": "textField"}` が要ります。既定の
  `focus: any` のままだと、ルールは空の入力で動きます。
- `command` のアクションでは、`replaceInput` は何も起こしません。書き換えた行は
  stdout に出ますが、voice-switch が捨てます。代わりに `output.shell`、`notify`、
  `background` を使うか、下の `keypipe` 配送を使ってください。
- `VOICE_SWITCH_APP` が空のときは `--app` ごと省きます。`--app ""` は `""` という
  アプリ名であって、前面アプリにはならないためです。

アクション側のキーは voice-switch の README（シェルコマンドへの受け渡し）にあります。

`replaceInput` の結果を貼り付けたいときは、`command` の代わりに voice-switch の
`keypipe` 配送を使います（Mac のみ）。voice-switch は `--line --report` で keypipe を
動かし、`replaced` の結果だけを貼ります。`superwhisperMode` には自動貼り付けが
オフのモードを指定します（voice-switch の README、keypipe delivery）。

```json
"keypipe": { "binary": "/usr/local/bin/keypipe", "config": "~/.config/keypipe/config.json" },
"macOS": { "actions": [
  { "name": "keigo", "wakeWords": ["けいご"], "keypipe": "@@@k", "superwhisperMode": "voice_switch" }
] }
```

## macOS のキー取得と Accessibility

`Sources/keypipe/MacKeyTap.swift` は listen-only の CGEventTap を張り、keypipe
自身が post した Backspace（`eventSourceUserData` の印）を除外し、各事象を
直列キューのエンジンに渡します。遅い変換が tap を止めないためです。ctrl、alt、
cmd のどれかが押されていればホットキー、それ以外は文字列照合器への文字です。
文字は keycode と shift から `UCKeyTranslate` で現在の配列に従って求めます。
前面アプリと同じ解釈です。`MacDesktop.swift` は `Desktop` の原始操作を Accessibility API
の上に実装します。最前面アプリのフォーカス要素が `AXTextField` / `AXTextArea`
なら欄、`AXTextInputMarkedRange` が空でなければ変換中、それ以外は `nothing`
です。通知は `osascript` の `display notification` に文字を引数で渡します。
どちらも `#if os(macOS)` でのみコンパイルされます。

デーモンは `keypipe` バイナリに Accessibility 許可（システム設定 >
プライバシーとセキュリティ > アクセシビリティ）が無いと起動を拒否します。
`keypipe --probe` は許可の有無と現在のスナップショットを JSON 1 行で出し、
ダイアログは出しません。実機で測った事実は `docs/design/verification-plan.md`
に、この経路を TextEdit と System Events で動かす検証は
`.claude/skills/verify-keypipe-rules/verify.sh` の M0〜M4 にあります。

## 構成

- `Package.swift`: Swift パッケージ `keypipe`、実行ターゲット `keypipe`、
  テストターゲット `keypipeTests`。
- `Sources/keypipe/main.swift`: エントリーポイント、`--config`、`--context`、
  `--smoke-feed`、`--feed-stdin`、`--probe`、`--triggers`、`--line`、macOS の
  デーモンループ。`--help` は使い方を出します。知らない引数は使い方を出して
  終了コード 2 で止まり、デーモンは起動しません。
- `Sources/keypipe/Config.swift`: 唯一の JSON 境界。理由付きで拒否する
  `loadConfig(path:)`。
- `Sources/keypipe/Context.swift`: `Focus`、`Field`、`Snapshot` と純粋なルール選択
  （`matches`、`select`）。
- `Sources/keypipe/Trigger.swift`: `Trigger`（文字列かホットキー）、`Hotkey` の
  解析、純粋なトリガーバッファマッチャー（最長一致優先、64 文字バッファ）。
- `Sources/keypipe/Engine.swift`: 発火手順（変換中の門、選択、読み戻し付きの消去、
  変換、送り先）。
- `Sources/keypipe/Shell.swift`: `runShell`。keypipe がコマンドを走らせる唯一の経路
  （stdin / `$1` / 環境変数、プロセスグループの期限）。
- `Sources/keypipe/Desktop.swift`、`FakeDesktop.swift`: デスクトップの境界
  （snapshot、backspace、text、setText、notify）と JSON 駆動の偽物。
- `Sources/keypipe/MacKeyTap.swift`、`MacDesktop.swift`: listen-only の
  CGEventTap と、デスクトップ境界の Accessibility 実装（macOS 専用）。
- `Tests/keypipeTests/`: トリガー、コンテキスト、設定、シェル、エンジンの単体テスト。
- `config.example.json`: echo する最小の `focus: any` ルール。

## フォーマットとテスト

```sh
swift test
swift-format lint --strict --recursive Sources Tests
```

`swift-format` がフォーマッタであり、リポジトリルートの `.swift-format` で
スタイル（4 スペース）を固定しています。上記の lint は終了コード 0 である
必要があります。Xcode だけの環境では `swift format lint ...` で同じ道具が動き、
`swift format format --in-place --recursive Sources Tests` で指摘の大半を直せます。
Linux ではボックスのツールチェーンに追加で
`LD_LIBRARY_PATH=/workspace/keypipe-mvp/scratch/swift-lib` が必要です
（そのディレクトリが存在する場合、`.claude/skills/verify-keypipe/verify.sh` がエクスポートします。ほかの verify スクリプトはしません）。

## 検証

ルールのパイプラインの検証スキルは `.claude/skills/verify-keypipe-rules/`
（`SKILL.md`、`verify.sh`、`probes/`）にあります。偽デスクトップの項目はどこでも
動き、実機の項目は Accessibility と Automation を許可した Mac が必要です。

```sh
.claude/skills/verify-keypipe-rules/verify.sh --no-live   # R 項目
.claude/skills/verify-keypipe-rules/verify.sh             # M 項目も（Mac）
```

`.claude/skills/verify-keypipe/` は MVP 時代の古いスキルで、改訂 3 より前の
スキーマを前提にしています。
