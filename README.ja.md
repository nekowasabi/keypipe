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
swift run keypipe --config ./config.example.json
# or
.build/debug/keypipe --config /path/to/keypipe.json
```

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
対象外です）。パスは `--config` で渡し、既定値は `./config.example.json` です。
まず `config.example.json` をコピーして開始してください。

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
- `when.app` は bundle id の一覧（省略で全アプリ）。`when.focus` は `textField` か
  `any`（既定）。`textField` のルールはテキスト要素にフォーカスがあるときだけ
  発火し、トリガーを消して欄を読み、それが入力になります。`any` のルールはどこでも
  発火し入力は空文字で、テキスト要素ならトリガーだけ消します。IME の変換中は
  何も発火しません。
- `transform` は省略可で、`/bin/sh -c` で走るシェルコマンドです。入力は stdin、
  `$1`、`KEYPIPE_INPUT` で受け、前面アプリは `KEYPIPE_APP` です。stdout から末尾の
  改行を 1 つ落としたものが結果です。非ゼロ終了、期限切れ（30 秒）、空の出力は
  何も送らず通知します。
- `output` は `"replaceInput"`（同じ欄に結果を書き戻す。`focus: textField` が必要）、
  `"notify"`、`"none"`（既定）、または `{ "shell": "..." }`（変換と同じ経路で結果を
  受ける）。クリップボードは `{ "shell": "pbcopy" }`、webhook は `curl` で書きます。
- 未知のキー、空の `trigger` / `transform` / `output.shell`、未知の `output` や
  `focus`、`focus: textField` の無い `replaceInput` は読み込み時に
  `invalid config: <理由>` で拒否し、終了コード 1 です。

## macOS のキー取得と Accessibility

`Sources/keypipe/MacKeyTap.swift` は listen-only の CGEventTap を張り、keypipe
自身が post した Backspace（`eventSourceUserData` の印）と Command 付きのキーを
除外し、打たれた文字を直列キューの `Engine.key` に渡します。遅い変換が tap を
止めないためです。`MacDesktop.swift` は `Desktop` の原始操作を Accessibility API
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
  `--smoke-feed`、`--feed-stdin`、`--probe`、macOS のデーモンループ。
- `Sources/keypipe/Config.swift`: 唯一の JSON 境界。理由付きで拒否する
  `loadConfig(path:)`。
- `Sources/keypipe/Context.swift`: `Focus`、`Field`、`Snapshot` と純粋なルール選択
  （`matches`、`select`）。
- `Sources/keypipe/Trigger.swift`: 純粋なトリガーバッファマッチャー
  （最長一致優先、64 文字バッファ）。
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
必要があります。Linux ではボックスのツールチェーンに追加で
`LD_LIBRARY_PATH=/workspace/keypipe-mvp/scratch/swift-lib` が必要です
（そのディレクトリが存在する場合、`verify.sh` がエクスポートします）。

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
