# keypipe 設計案: 処理ごとのフォールバックと、構造を先に直す順序

[`context-rules.md`](context-rules.md)（改訂 3）への追加。2026-10-31 の設計 arena（候補 2 本、[`arena-2026-10-31/fallback-candidate-1.md`](arena-2026-10-31/fallback-candidate-1.md) と [`fallback-candidate-2.md`](arena-2026-10-31/fallback-candidate-2.md)）の統合。実装前。

## Problem

利用者の目的。ルールの段（変換、送り先）が失敗したとき、ルールごとに代替を書きたい。代替は疎結合に足せること。現 MVP の構造を先に改訂 3 の形へ直し、その後で機能を実装したい。

形が自明でない理由。

- 失敗には二種類ある。シェルの中で見える失敗（非ゼロ終了）はシェルの `||` が既に書ける。シェルから見えない失敗（エンジンが期限で殺した、変換が空を返した、`AXValue` の書き込みが無視された、欄が消えた）はシェルでは書けない。
- 「プラグイン形式」と「振る舞いは設定だけで宣言する。プラグインコードは持たない」がぶつかる。本案はシェル境界をそのままプラグインの口とみなす。新しい代替は設定のシェル文字列で書け、Swift を触らない。制約は変えない。
- 期限が無いと、固まった `claude -p` が直列の発火キューを永久に止め、どの代替も走らない。標準の macOS に `timeout(1)` は無い（この Mac では `/opt/homebrew/bin/timeout` だけ。実測）。

## Usage (caller's view)

ルールに `onFail` を足す。キーは段の名前、値はその段と同じ書き方。

- `onFail.transform` は `transform` と同じ文字列のシェルコマンド。`transform` が非ゼロで終わった、期限を過ぎた、空を出した、のいずれかのとき、**同じ入力**で一度だけ走る。その stdout が結果になり、本来の `output` へ進む。
- `onFail.output` は `output` と同じ値（`"notify"` / `"none"` / `"replaceInput"` / `{ "shell": "..." }`）。本来の送り先が失敗したとき、**同じ結果**を受けて一度だけ走る。
- 代替のシェルは環境変数 `KEYPIPE_FAILURE` で理由を受ける。値は `exit <n>` / `timeout` / `empty` / `ignored` / `gone`。理由で分けたいならシェルの中で分ける。
- 代替自身が失敗したら通知して終わる。代替の代替は書けない。
- `onFail` が無いときの既定。変換の失敗は通知（今と同じ）。`replaceInput` の失敗は結果の文字を通知（文字を失わない）。`output.shell` の失敗は記録だけ（今と同じ）。
- 最上位の `shellTimeout`（秒、既定 30）が、変換、`output.shell`、それぞれの代替、すべてのシェルの期限。過ぎたらプロセスグループごと止める。
- 「どのルールも満たさなかったら X」は、同じトリガーで `when` を書かないルールを末尾に置く。設定順で最初に満たしたルールが勝つ規則が既にあるので、新しいキーは無い。

使い分けの目安。一つの行き先の中の言い換え（`claude -p` が駄目なら `curl`）はシェルの `||`。別の行き先へ逃がす、または期限切れ・空出力・書き込み無視を拾うなら `onFail`。

設定エラー（`invalid config: <理由>`、検証は文字どおり照合する）。

| 設定 | 理由 |
| --- | --- |
| `transform` が無いのに `onFail.transform` | `onFail.transform requires transform` |
| `output` が `none` か `notify` なのに `onFail.output` | `onFail.output requires an output that can fail` |
| `focus: any` で `onFail.output: "replaceInput"` | `output replaceInput requires focus textField`（`output` と同じ検査） |
| `onFail.erase` など未知の段 | `unknown key erase` |
| `onFail.transform: ""` / `onFail.output: {"shell": ""}` | `empty transform` / `empty output.shell`（本来の値と同じ検査） |
| `shellTimeout` が正の数でない | `shellTimeout must be positive` |

### (a) その場で翻訳。`claude -p` が失敗か期限切れなら別の API

```json
{
  "shellTimeout": 20,
  "rules": [
    {
      "trigger": "@@@",
      "when": { "app": ["com.apple.TextEdit"], "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput",
      "onFail": { "transform": "curl -sS -m 5 https://api.example.com/translate --data-urlencode text@-" }
    }
  ]
}
```

`claude -p` が 20 秒で返らないとき。

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe transform timeout 20
keypipe fallback transform exit 0
keypipe apply replaceInput "Hello"
```

両方失敗したとき。欄は消去後の `こんにちは` のまま。

```
keypipe transform exit 1
keypipe fallback transform exit 6
keypipe apply notify "@@@ transform failed: exit 6"
```

### (b) 欄の文字を tmux へ送り、宛先が無ければクリップボードに残す

```json
{
  "trigger": ";;t",
  "when": { "focus": "textField" },
  "output": { "shell": "tmux send-keys -t work:claude -l -- \"$1\" && tmux send-keys -t work:claude Enter" },
  "onFail": { "output": { "shell": "pbcopy" } }
}
```

```
keypipe matched ;;t rule 1
keypipe erase 3
keypipe output-shell exit 1
keypipe fallback output-shell exit 0
```

tmux が固まって返らないときは `keypipe output-shell timeout 20` の後に同じ代替が走る。`|| pbcopy` で書くと、この場合だけ代替が走らない。

### (c) `replaceInput` の書き込みが無視されたら結果をクリップボードへ

```json
{
  "trigger": "@@e",
  "when": { "app": ["com.tinyspeck.slackmacgap"], "focus": "textField" },
  "transform": "claude -p 'Translate to English. Output only the translation.'",
  "output": "replaceInput",
  "onFail": { "output": { "shell": "pbcopy" } }
}
```

```
keypipe transform exit 0
keypipe apply-failed replaceInput ignored
keypipe fallback output-shell exit 0
```

変換の間に窓を閉じたときは `apply-failed replaceInput gone`。今フォーカスしている別の欄には書かない。`onFail` が無ければ最後の行は `keypipe apply notify "Hello"`。

## 失敗点ごとの扱い

| # | 失敗点 | 誰が見えるか | 扱い |
| --- | --- | --- | --- |
| 1 | `composing` | エンジン | 失敗ではない。発火しない（改訂 3） |
| 2 | `nomatch` | エンジン | 新しいキーは無い。`when` の無い受け皿ルールを末尾に置く |
| 3 | 消去の読み戻しが期限切れ | エンジン | 失敗ではない。「Backspace 無視」の合図で、書き戻しへ進む（改訂 3 手順 5） |
| 3' | 書き戻しも無視、欄が消えた | エンジン | 固定。欄が消えたら発火を終える。それ以外は続行し `erase-failed <理由>` を出す。ルールごとに選ぶ価値が無い（中止すると遅い変換の結果ごと失う） |
| 4 | `transform` 非ゼロ | シェルとエンジン | `onFail.transform`。既定は通知 |
| 4' | `transform` 期限切れ | エンジンだけ | `onFail.transform`。期限は `shellTimeout` |
| 5 | `transform` が 0 で空出力 | エンジン | 失敗 `empty` として `onFail.transform`。空を `replaceInput` に渡して欄を消さない。「通知して止める」部分は段 5 で先行実装済み（R5d）。`onFail` への接続は段 7 |
| 6 | `output.shell` 非ゼロ | シェルとエンジン | `onFail.output`。既定は記録だけ |
| 7 | `replaceInput` の書き込み無視 | エンジンだけ | `onFail.output`。既定は結果を通知 |
| 8 | 欄のハンドル失効 | エンジンだけ | 7 と同じ。今のフォーカスには書かない |
| 9 | `output.shell` 期限切れ | エンジンだけ | `onFail.output` |
| - | 代替自身の失敗 | エンジン | 固定。通知して終わる。一発火のシェルは高々 4 本、所要は `4 × shellTimeout + 消去の期限` が上限 |

追加する出力行（既存の行は変えない）。

| 行 | 意味 |
| --- | --- |
| `keypipe transform timeout <秒>` / `keypipe output-shell timeout <秒>` | 期限で殺した。`exit` 行は出ない |
| `keypipe transform empty` | 0 で終わったが出力が空 |
| `keypipe fallback transform exit <n>` / `keypipe fallback transform timeout <秒>` / `keypipe fallback output-shell exit <n>` | 代替の結果 |
| `keypipe apply-failed replaceInput ignored\|gone` | 書き込みが無視された、欄が消えた。`apply replaceInput` は読み戻しが一致したときだけ出す |
| `keypipe erase-failed rewrite-ignored\|trigger-absent` | 書き戻しの失敗。続行する |

`verify.sh` の `has` / `lacks` は部分一致（`grep -F`）なので、`erase` と `erase-rewrite` / `erase-failed` のように接頭辞を共有する行は、照合文字列を `keypipe erase ` のように末尾の空白まで書く。`lacks R3c` はそのように直した。`--smoke-feed` の終了コードは、ルールが一致すれば段が失敗しても 0。R9 はこれを前提に `exitis 0` を主張できる。

## Shape

### データ

```swift
// Config.swift  JSON の境界。ここより内側は構築時点で正しい。
struct Guarded<Value: Equatable>: Equatable {
    var primary: Value
    var onFail: Value?       // Value であって Guarded<Value> ではない。代替の代替は表せない
}
struct Rule: Equatable {
    var trigger: String
    var when: When
    var transform: Guarded<String>?   // nil は恒等。transform が無ければ onFail.transform も無い
    var output: Guarded<Output>
}
struct KeypipeConfig: Equatable {
    var rules: [Rule]
    var shellTimeout: TimeInterval    // 既定 30
}
// loadConfig は primary と onFail を同じ解析関数（parseTransform / parseOutput）に通す。
// replaceInput は focus: textField でだけ許す検査を両方に掛ける（改訂 3 の検査一つの流儀）。
```

```swift
// Engine.swift  失敗の分類と代替の方針はここだけ。
enum Failure: Equatable {
    case exit(Int32), timeout, empty, ignored, gone
    var token: String   // "exit 3" | "timeout" | "empty" | "ignored" | "gone"。出力行と KEYPIPE_FAILURE の両方に使う
}
enum ShellOutcome: Equatable { case exited(Int32, stdout: String), timedOut(seconds: Int) }
enum WriteOutcome: Equatable { case written, ignored, gone }

struct Engine {
    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (_ cmd: String, _ input: String, _ env: [String: String], _ timeout: TimeInterval) -> ShellOutcome,
         emit: @escaping (String) -> Void)
    mutating func key(_ c: Character)

    // TODO fire(trigger): snapshot, composing 門, select, erase（改訂 3 手順 4-5）, then
    //   result = runStage(.transform, rule.transform, input)      // primary, 失敗なら onFail を同じ入力で一度
    //   runStage(.output, rule.output, result)                    // primary, 失敗なら onFail を同じ結果で一度
    //   代替も失敗なら notify して終わる
    /// 段を一度試し、失敗なら onFail を一度試す。各試行の行を出す。失敗の理由を Failure で返す。
    private func runStage<V>(_ stage: Stage, _ g: Guarded<V>, _ text: String) -> Result<String, Failure>
}

/// 改訂 3 手順 5 を Desktop の原始操作の上に一度だけ書く。Mac と Fake で手順がずれない。
func performErase(_ f: Field?, trigger: String, _ d: Desktop) -> EraseOutcome
/// setText が false なら gone、読み戻しが違えば ignored。
func performWrite(_ f: Field, _ s: String, _ d: Desktop) -> WriteOutcome
```

```swift
// Desktop.swift  原始操作だけ。消去の手順は持たない。
protocol Desktop {
    func snapshot() -> Snapshot
    func backspace(_ count: Int)                   // keypipe の eventSourceUserData を付ける
    func text(_ f: Field) -> String?               // nil はハンドル失効
    func setText(_ f: Field, _ s: String) -> Bool  // false はハンドル失効
    func notify(_ s: String)
}
// FakeDesktop の --context に足すキー:
//   "ignoresWrite": bool   setText は true を返すが text() は変わらない → ignored
//   "fieldGoneAfter": "erase"   消去の後に text()/setText() が失効を返す → gone
```

```swift
// Shell.swift  Actions.swift を置き換える。keypipe がコマンドを走らせる唯一の経路。
/// /bin/sh -c <script> keypipe <input>。入力は stdin と $1 と KEYPIPE_INPUT。
/// posix_spawn + POSIX_SPAWN_SETPGROUP で自分のプロセスグループに置き、期限で SIGTERM、1 秒後に SIGKILL をグループへ送る。
/// Process.terminate() は sh しか止めず claude が残る（推測、未検証）。末尾の改行を一つ落とす。
func runShell(_ script: String, input: String, env: [String: String], timeout: TimeInterval) -> ShellOutcome
```

### 判断と原則

- 代替は段の語彙で書く。`onFail.transform` は `transform` と、`onFail.output` は `output` と同じ型で、同じ解析関数を通る。代替専用の語彙（`retry`、種類名の表）は作らない。送り先の種類が増えれば代替にもそのまま使える。model-the-domain による。
- 書けない組み合わせは型か検査で消す。代替の代替は `Guarded.onFail: Value?` で型から消す。`transform` の無いルールの `onFail.transform` は `Guarded<String>?` で消す。`replaceInput` の `focus` 条件は `loadConfig` の検査（改訂 3 の流儀）。`Scope` の入れ子は入れない。欄の有無で分岐する箇所が増えたら見直す。
- 失敗の方針は `Engine.runStage` 一つに集める。`select`、`TriggerMatcher`、`Desktop` は失敗を知らない。
- 消去の手順は `performErase` として一度だけ書き、`MacDesktop` と `FakeDesktop` は原始操作だけを実装する。偽の検証が本物を保証するため。boundary-discipline による。
- 期限はエンジンが持ち、設定の最上位に一つ。`verify.sh` は各送りを `cap 20` で包むので、設定で短くできないと期限の項目を検証できない。
- 出力行は確かめた後に出す。`apply replaceInput` は読み戻し一致のときだけ。そうしないと `lacks 'apply replaceInput'` の判定が意味を失う。
- プラグイン実行系は作らない。シェルがプロセス境界の外にあるプラグインの口で、任意の言語で書け、再ビルドが要らない。型の語彙を名前で引く登録表にすると、シェルと同じことの二通り目になる。

### 次の代替を足す人へ

1. `{ "shell": ... }` を `onFail.output` か `onFail.transform` に書けば表せるか。tmux のセッション作成、`pbcopy`、webhook、ファイル追記、`say`、`KEYPIPE_FAILURE` による分岐。ほとんどはここで終わる。設定の編集だけ。
2. シェルに無い能力（AX でしか書けない、キーを打つ）が要るなら、代替の種類ではなく送り先の種類。`BuiltinSink` に case を一つ、`loadConfig` の文字列、`Engine` の網羅的な `switch` が示す分岐、必要なら `Desktop` の原始操作一つ。足した送り先は本来の送り先にも代替にも使える。最初の候補は「全選択して貼り付け」で、Electron が `AXValue` の書き込みを本当に無視するか測ってから。
3. 新しい失敗の種類（出力が長すぎる等）は `Failure` に case 一つと `runStage` の分類一行。

## Synthesis decision

候補 2 本、ともに Claude Opus（別系統の判定役はこのホストに無く、置いていない）。候補 1 は `onFailure` 一つ（`Output` 型を再利用、救済専用）、固定 30 秒、命令的 Engine。候補 2 は段ごとの `onFail.{transform,output}`、設定の `shellTimeout`、`Guarded` と `Scope` の入れ子、純粋な reducer と解釈器。

基準は 5 つ。失敗点 9 か所すべてに扱いがあること（両方満たす）。代替の追加が設定の編集で済むこと（両方満たす）。偽 Desktop で検証できること（候補 2。固定 30 秒は `cap 20` の中で検証できない）。同じことに二通りの書き方を作らないこと（両方 `||` と重なる。候補 2 の `onFail.transform` は期限切れと空出力の後で本来の `output` へ進めるので `||` に無い能力がある）。改訂 3 からの差分（候補 1 が小さい）。

基底は候補 2 の**設定の語彙**（段ごとの `onFail`、`shellTimeout`、`Guarded`、`KEYPIPE_FAILURE`、出力行）。利用者の求め「処理ごとのフォールバック」に直接対応し、変換の代替が本来の送り先へ進める点が救済専用の `onFailure` より強い。

候補 1 から移植した点。

- Engine は命令的なまま。`runStage` 一つに失敗の方針を集め、reducer と解釈器の分離（`Fire.swift`、継続を運ぶ `Next`）は入れない。表駆動の試験は FakeDesktop を同プロセスで使えば足り、ファイルと型を増やす根拠が無い。
- `Scope` の入れ子は入れず、`replaceInput` の `focus` 条件は検査一つのまま（改訂 3 の判断を維持）。
- 新しい失敗の種類の足し方（`Failure` に case 一つ）。

候補 2 から移植し候補 1 を退けた点。

- 期限は設定の `shellTimeout`。検証可能性のため。
- 出力行は段ごと（`fallback transform exit`、`apply-failed`）。候補 1 の `fail <stage> <status>` 一行より、どの試行が何を返したかが読める。
- Desktop は原始操作 5 つ、消去と書き込みの手順は共有関数。

両候補が一致した点。`nomatch` にキーは足さない。空出力は失敗。`replaceInput` の失敗の既定は結果の通知。`output.shell` の失敗の既定は記録だけ。代替の代替は無し。プラグイン実行系は作らない。構造の改善を 5〜6 段で先に終え、機能はその後。

## Tradeoffs accepted

- 非ゼロ終了の代替は `||` でも `onFail` でも書ける重なりを受け入れる。代わりに期限切れ、空出力、書き込み無視をシェルの外で同じ一か所で扱える。
- 空出力を常に失敗とみなす。代わりに `replaceInput` が欄を空で消す経路が無くなる。空を送りたい実例は無い。
- 消去の失敗は固定の続行。トリガーが欄に見えたまま残ることがある（壊さない、見える）。
- `shellTimeout` は全シェルで一つ。一発火の上限は `4 × shellTimeout`。
- `output.shell` の失敗の既定は記録だけ。`onFail` を書かない利用者は tmux の宛先違いに気づきにくい。
- Engine を命令的に保つ。代わりに失敗の表の試験は FakeDesktop 経由になる。

## Open questions and risks

- `shellTimeout` 既定 30 秒で `claude -p` の長文が収まるか。設定で変えられるので運用で測る。ルールごとの期限は要望が出てから。
- Electron の欄で `setText` 後の読み戻しが一致しないとき、遅れて反映されることがあるか。あると `pbcopy` と二重になるが欄は壊れない。
- 閉じた窓の `AXUIElement` への書き込み。**実測（2026-11-01、TextEdit）**: 黙って成功を返し、読み戻しは古い値のまま。変換中（`sleep 3`）に文書を閉じると `apply-failed replaceInput ignored` と `apply notify "HELLO"` が出た。`gone` ではなく `ignored` に分類されるが、結果は通知され別の欄には書かない。`gone` が実機で出る条件（アプリ終了など）は未測定。
- `POSIX_SPAWN_SETPGROUP` で切り離したグループが端末の SIGINT を受けない副作用は daemon で問題にならないか（推測）。
- `replaceInput` 失敗の既定通知に結果の全文を載せてよいか（通知センターに残る）。

## 構造を先に直す順序

各段は単独で入り、終わりに `swift test` か `verify.sh --no-live` の特定の項目が緑になる。段 1〜5 は利用者に見える能力を増やさない。機能は段 6 から。

| 段 | 何を | 触るファイル | 確認 |
| --- | --- | --- | --- |
| 1 | 消す。`log` アクションと `logPath` | `Sources/keypipe/Actions.swift`, `Config.swift`, `main.swift`, `Tests/keypipeTests/ActionsTests.swift`, `config.example.json` | `swift test` |
| 2 | 照合器はトリガー文字列だけを返す。`TriggerRule` と `contextMatches` を消す。規則の引き当ては `main.swift` の `feedAndRun` で設定順の最初 | `Trigger.swift`, `main.swift`, `TriggerTests.swift`, `TriggerExhaustiveTests.swift`, `.claude/skills/verify-keypipe-trigger/` | `swift test`、verify-keypipe-trigger、`--smoke-feed '@@@'` の出力行が不変 |
| 3 | シェルを一本にし期限を付ける。`Shell.swift` の `runShell`（stdin、`$1`、`KEYPIPE_INPUT`、プロセスグループ、期限は定数 30）。`Actions.swift` 削除 | `Shell.swift`（新規）, `ShellTests.swift`（`ActionsTests.swift` を置換） | `swift test`。`sh -c 'sleep 30 & wait'` が短い期限で `.timedOut`、子の `sleep` も残らない（`kill -0`）。`$()` とバッククォートが `$1` にバイト単位で届く |
| 4 | 新しい設定の境界。改訂 3 のスキーマ、`Guarded`、未知キー拒否、R2 の理由文字列（`onFail` と `shellTimeout` はこの段では `unknown key` で拒否）。`Context.swift` は `Focus` / `Field` / `Snapshot` / `select`。`main.swift` は `Snapshot(focus: .nothing)` を渡す仮配線 | `Config.swift`, `Context.swift`, `main.swift`, `ConfigTests.swift`, `ContextTests.swift`, `config.example.json` | `swift test`、`verify.sh --no-live` の R2a〜f |
| 5 | 境界と発火手順。`Desktop` の原始操作 5 つ、`FakeDesktop`（`--context`）、`Engine`（改訂 3 の手順と固定の方針「変換失敗で通知」）、`performErase` / `performWrite`、`main.swift` の `Engine` 配線と `keypipe field` | `Desktop.swift`, `FakeDesktop.swift`, `Engine.swift`, `main.swift`, `EngineTests.swift` | `verify.sh --no-live` の R2〜R8 全 PASS。**ここで構造の改善は終わる** |
| 6 | 実機。listen-only CGEventTap、自分の事象の除外、配送後にメインキューで `Engine.key`、`MacDesktop` の原始操作、`--probe` | `MacKeyTap.swift`, `MacDesktop.swift`, `main.swift` | Mac で `verify.sh` の M0〜M4 |
| 7 | 代替。`onFail`、`shellTimeout`、拒否理由 4 つ、`Failure.empty/ignored/gone`、`KEYPIPE_FAILURE`、新しい出力行、`FakeDesktop` の `ignoresWrite` と `fieldGoneAfter` | `Config.swift`, `Engine.swift`, `FakeDesktop.swift`, `verify.sh`, `SKILL.md`, `config.example.json`, `README*.md`, 本書 | `swift test`、`verify.sh --no-live` の R9（下表） |
| 8（保留） | 全選択して貼り付け | `BuiltinSink.paste`, `Desktop.paste`, `MacDesktop`, `FakeDesktop` | Electron で `AXValue` 無視を測ってから |

段 7 の検証項目。

| ID | 何を | 合否 |
| --- | --- | --- |
| R9a | `shellTimeout: 1`、`transform: "sleep 5"`、`onFail.transform: "tr a-z A-Z"` | `transform timeout 1`、`fallback transform exit 0`、欄 `"HELLO"`、`cap 20` 内で終わる |
| R9b | `transform: "exit 3"`、`onFail.transform: "exit 4"` | `fallback transform exit 4`、`apply notify`、`apply replaceInput` 無し、欄 `"hello"` |
| R9c | `transform: "true"`、`onFail` 無し | `transform empty`、`apply notify`、欄 `"hello"` |
| R9d | `output.shell: "exit 1"`、`onFail.output.shell` が副作用ファイルへ `$1` と `$KEYPIPE_FAILURE` | `output-shell exit 1`、`fallback output-shell exit 0`、ファイルが `hello` と `exit 1` |
| R9e | `"ignoresWrite": true`、`replaceInput`、`onFail.output.shell` が副作用ファイル | `apply-failed replaceInput ignored`、`apply replaceInput` 無し、ファイルが結果 |
| R9f | `"fieldGoneAfter": "erase"`、`replaceInput`、`onFail` 無し | `apply-failed replaceInput gone`、`apply notify "HELLO"` |
| R9g | 代替も期限切れ（`onFail.transform: "sleep 5"`） | `fallback transform timeout 1`、`apply notify`、シェルは 2 本で止まる |
| R9h〜k | 拒否 4 種 | exit 1 と理由の文字列 |
| R9l | 受け皿ルール（同じトリガー、`when` なし）が先行ルール不成立で `matched @@@ rule 1` | `nomatch` 無し |

順序の理由。1 で消してから形を変えるので各段の差分が小さい。期限（3）を実機（6）より前に入れるのは、実機で最初に `claude -p` が固まった時点で daemon が止まるのを防ぐため。6 を 7 より先にするのは、M1〜M3 が MVP の合格条件で、`ignored` と `gone` を実機の `performWrite` で確かめられるのが 6 の後だから。

## 実装の記録

- 段 1〜5（2026-10-31）、段 6（2026-11-01、実機 M0〜M6）、段 7（2026-11-01、R9a〜l）まで実装済み。残りは段 8（保留）。
- 段 7 で設計から変えた点。`Engine.runStage` は `runTransform` / `shellStage` / `apply` の 3 関数になった。`fallback` の出力行は代替の試行すべてに `fallback ` を前置する（`fallback apply replaceInput ...` も含む）。`performErase` は欄が消えたときだけ nil を返し、`trigger-absent` と `rewrite-ignored` は行を出して続行する。`FakeDesktop` の `fieldGoneAfter: "erase"` は「消去後の最初の書き込みが失敗し、以後の読みが nil」として近似した（消去の読み戻し中に消えると発火が終わるだけで `gone` の経路に入らないため）。`ignoresWrite` は結果が欄と同じ文字のとき観測できない（読み戻しが一致する）。
- 次の候補。段 8 は Electron で `AXValue` 無視を測ってから。
