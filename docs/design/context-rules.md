# keypipe 設計案: コンテキスト付きルール（改訂 2）

レビュー用の設計スケッチ。実装前。改訂 2 はレビュー回答（選択は扱わない、変換と送り先は差し替え可能）を反映した。

## Problem

今の keypipe は「トリガー文字列 → shell か log」だけを持つ。`MatchContext` はあるが `contextMatches` は常に true で、`TriggerMatcher.feed` は `app: nil` で呼んでいる。キー取得（CGEventTap）も未配線。

やりたいことは、トリガー入力を起点に、その瞬間の状況（前面アプリ、フォーカスがテキスト欄か）でルールを選び、欄の文字を変換に通し、結果を設定した送り先へ渡すこと。変換（シェルスクリプト、`claude -p`、API 呼び出し）も送り先（欄の置換、tmux、Herdr、Grok Bot、CotEditor、任意のスクリプトの引数）も、設定だけで差し替えられるようにする。

形が自明でない理由は二つ。

- 同じトリガーを状況違いの複数ルールが共有する。今の matcher はバッファだけでルールを一つに決めてしまう。
- 打ったトリガー文字はアプリに届く。`@@@` を消さないと欄のテキストに混ざる。

守る制約。トリガー長 64 文字上限と最長一致優先は維持する。Linux では `--smoke-feed` と `--feed-stdin` で経路全体を動かせることを維持する。

扱わないもの。選択テキスト（レビュー回答 1）。

## Usage (caller's view)

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "when": { "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput"
    },
    {
      "trigger": "@@e",
      "when": { "focus": "textField" },
      "transform": "curl -s https://api.example.com/translate --data-urlencode text@-",
      "output": "replaceInput"
    },
    {
      "trigger": ";;;",
      "when": { "focus": "textField", "app": ["com.googlecode.iterm2"] },
      "output": { "shell": "tmux new-window -t work -- claude \"$1\"" }
    },
    {
      "trigger": ";;g",
      "when": { "focus": "textField" },
      "output": { "shell": "agmsg send gb \"$1\"" }
    }
  ]
}
```

意味。

- `trigger` 直近のキー入力の末尾がこれに一致したら候補になる。
- `when` 省略したキーはワイルドカード。`focus` は `textField` か `any`。`app` は bundle id のどれか。同じトリガーの候補は設定順で最初に満たしたものが勝つ。
- 欄の文字（トリガーを消した後）が入力になる。フォーカスがテキスト欄でなければ入力は空文字。
- `transform` 省略可。シェルコマンド。入力を stdin と `$1` と `KEYPIPE_INPUT` で受け、stdout が結果になる。省略すると入力がそのまま結果になる。
- `output` 結果の行き先。二種類のどちらか。
  - 組み込み（アプリ内でしかできないもの）。`"replaceInput"` / `"insert"` / `"clipboard"` / `"notify"` / `"none"`。
  - 外部（それ以外全部）。`{ "shell": "..." }`。結果を stdin と `$1` と `KEYPIPE_INPUT` で受ける。tmux、Herdr、Grok Bot、CotEditor、任意スクリプトの引数はすべてこちらで書く。CotEditor なら `{ "shell": "printf %s \"$1\" | cot" }` のように同梱の `cot` コマンドへ渡す。
- 環境変数 `KEYPIPE_APP` に前面アプリの bundle id を入れる。

発火の手順は固定。

1. matcher がトリガー一致を報告する。
2. その時点のスナップショット（前面アプリ、フォーカス種別）で `when` を評価し、ルールを一つ選ぶ。満たすルールが無ければ何もしない。
3. トリガー文字数ぶん Backspace を送って消す。
4. 欄の文字を読む。
5. `transform` を実行する。非ゼロ終了なら送り先へ渡さず通知する。
6. `output` を適用する。

## Shape

### データ

```swift
// Config.swift  境界。JSON をここで全部検証する。
enum Focus: String, Codable { case textField, any }

enum BuiltinSink: String, Codable { case none, replaceInput, insert, clipboard, notify }
enum Output: Equatable { case builtin(BuiltinSink), shell(String) }   // JSON は文字列か {"shell"}

struct When: Equatable {
    var app: [String]?     // nil はワイルドカード
    var focus: Focus       // 省略時 .any
}

struct Rule: Equatable {
    var trigger: String
    var when: When
    var transform: String?  // nil は恒等
    var output: Output      // 省略時 .builtin(.none)
}

struct KeypipeConfig: Equatable { var rules: [Rule] }

// Context.swift  状況のスナップショットと純粋な判定。
struct Snapshot: Equatable {
    var app: String?
    var focusIsTextField: Bool
}
func matches(_ when: When, _ s: Snapshot) -> Bool { notImplemented() }
func select(_ candidates: [Rule], _ s: Snapshot) -> Rule? { notImplemented() }
```

### 境界のポート

```swift
// Desktop.swift
protocol Desktop {
    func snapshot() -> Snapshot
    func erase(_ count: Int)
    func fieldText() -> String
    func apply(_ sink: BuiltinSink, text: String)
}
// MacDesktop.swift   #if os(macOS)。AXUIElement と CGEvent はこのファイルの外に出さない。
// FakeDesktop.swift  JSON で状況と欄の文字を与え、erase/apply の呼び出しを記録して出力する。
```

実装は二つ。macOS の AX 実装と、テストと Linux の feed モードで使う偽物。対象 OS は macOS のみ。検証は利用者が Mac で別途行う。

### 流れ

```swift
// Engine.swift  発火手順 1-6 を持つ唯一の場所。
struct Engine {
    init(config: KeypipeConfig, desktop: Desktop, shell: (_ cmd: String, _ input: String, _ env: [String: String]) -> (Int32, String))
    mutating func key(_ c: Character)
}
```

- `TriggerMatcher.feed` は一致した `trigger: String` を返す。ルール選択は `select` に移す。
- `shell` は注入する。本番は `/bin/sh -c <cmd> keypipe <input>` で `$1` に入力が入る。テストでは記録するだけの関数。
- `transform` と `output.shell` は同じ `shell` 関数を通る。変換も送信も「シェルに文字を渡す」一つの仕組み。

### 判断と原則

- 送り先を「アプリ内でしかできない組み込み」と「シェル」の二種類の判別共用体にした。tmux 型や Grok Bot 型を足し続ける if の連鎖を作らない。model-the-domain による。
- AX と CGEvent の型は `MacDesktop` に閉じる。JSON の検証は `loadConfig` だけで行う。boundary-discipline による。
- 変換と外部送信は同じ `shell` 経路を共有し、専用の型を作らない。`log` アクションは消す。laziness-protocol による。

### 意図的にやらないこと

- 選択テキスト。
- 変換や送り先の名前付き再利用（同じ `transform` を複数ルールで共有する定義）。同じ文字列を三回書くようになったら足す。
- 多段パイプライン記法。シェルのパイプで書ける。
- 設定のホットリロード。TOML/YAML。

## Synthesis decision

arena の複数モデル実行は回していない。候補は自分で比較した。

- 候補 A（採用）。`when → transform → output` の固定の組。output は組み込みかシェル。
- 候補 B。`steps: [...]` の自由なステップ列。シェルのパイプと二通りの書き方になる。不採用。
- 候補 C（一部採用）。トリガー検出だけして状況を環境変数で渡す極小案。欄の読み書きがシェルからできないので単独では成り立たない。環境変数で状況を渡す部分だけ取り込んだ。

## Tradeoffs accepted

- 変換と送信がシェル一本である代わりに、利用者はクォートを自分で書く。`$1` を用意してクォート事故を減らす。
- 旧スキーマ（`action.type`, `context.appBundleId`）との互換は捨てる。
- `transform` と `output.shell` は同期実行。`claude -p` の数秒間、次の発火は待たされる。キー取得自体は止めない。

## リスク（未検証）

- 一部アプリ（Electron 系）は `AXValue` の書き込みを無視する。`replaceInput` は書き込み後に読み戻し、失敗したら「全選択してペースト」に落とす。
- ターミナル（iTerm2）のプロンプトは AX 上テキスト欄ではない可能性が高い。その場合 `;;;` の例は `focus: any` にし、欄の文字は取れない。

## 検証のための追加契約

`.claude/skills/verify-keypipe-rules/` が前提にする振る舞い。設計本文への追加なのでレビュー対象。

- 未知のキーを持つ設定は拒否する。旧スキーマ（`action`）が「何もしないルール」として黙って読み込まれるのを防ぐ。
- `transform` の出力は末尾の改行を一つだけ落とす。`claude -p` や `echo` が付ける改行を欄に入れないため。
- `focus: textField` は AX のテキスト欄とテキストエリア（複数行）の両方を含む。
- `--context <json>` で `FakeDesktop` に状況を与える。打ったキーは `fieldText` の末尾に足され、erase は末尾から消す。
- `--probe` は Accessibility の許可と現在のスナップショットを JSON 1 行で出す。利用者が `when.app` の bundle id を調べる用途も兼ねる。
- 発火の各段で `keypipe matched / nomatch / erase / transform exit / apply / output-shell exit / field` の行を出す。形式は `SKILL.md` の表。

## 変更範囲

- `Sources/keypipe/Trigger.swift` 一致したトリガー文字列を返す。
- `Sources/keypipe/Context.swift` `MatchContext` を消し `When`, `Snapshot`, `matches`, `select`。
- `Sources/keypipe/Config.swift` 新スキーマと検証。
- `Sources/keypipe/Actions.swift` 削除。`Engine.swift` と shell 実行に置き換え。
- `Sources/keypipe/Desktop.swift`, `FakeDesktop.swift`, `MacDesktop.swift` 新規。
- `Sources/keypipe/MacKeyTap.swift` 実際の CGEventTap。
- `Sources/keypipe/main.swift` Engine の配線。`--smoke-feed` と `--feed-stdin` に `--context <json>` を追加。
- `Tests/keypipeTests/` 5 ファイルを新スキーマに合わせる。
- `config.example.json`, `README.md`, `README.ja.md`。
- `.claude/skills/verify-keypipe*/` 旧スキーマ前提の三つ。
