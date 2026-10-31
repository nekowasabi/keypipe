# 候補 1（最小）: 失敗時の受け口は `onFailure` 一つ、差し込み口はシェル

対象は改訂 3（`docs/design/context-rules.md`）。そこからの差分だけを書く。

## Problem

利用者の目的。トリガーを打つと欄の文字が変換を通って送り先へ届く。これを JSON 一つで宣言する keypipe に、ルールごとの「失敗したときどうするか」を、コアを触らずに足せる形で入れたい。足す前に、今の MVP（旧スキーマ `trigger` + `action`、`MatchContext` は常に true、tap 未配線）を改訂 3 の形へ直す。

形が自明でない理由は三つ。

- 失敗には二種類ある。シェルの中の失敗（`claude -p` の非ゼロ終了、tmux の対象が無い）と、シェルから見えない失敗（`AXValue` の書き込みが無視された、欄が閉じた、エンジンが時間切れで殺した）。前者はシェルの `||` が既に書ける。後者はシェルでは書けない。
- 「プラグイン的」と「設定だけが宣言の場、プラグインコードは持たない」がぶつかる。この候補はシェル境界をそのまま差し込み口とみなす。新しい後始末は設定のシェル文字列一つで書け、Swift を触らない。制約は変えない。
- 直列の発火キューは、ハングした `claude -p` で永久に止まる。時間切れが無いと、どの後始末も走らない。

守る制約。設定が唯一の宣言面。`Desktop` が唯一の AX/CGEvent 境界。JSON の検証は `loadConfig` だけ。transcript 行は追加のみ。抽象は実装が二つ以上あるときだけ。

## Usage (caller's view)

足すキーは一つ。

- `onFailure` 省略可。ルールが結果を届けられずに終わったときの行き先。値は `output` と同じ形で、`"notify"`（既定）、`"none"`、`{ "shell": "..." }` のどれか。`"replaceInput"` は設定エラー（`onFailure cannot be replaceInput`）。
- `onFailure` のシェルは、届けるはずだった文字を `output.shell` と同じく stdin、`$1`、`KEYPIPE_INPUT` で受ける。どの段がなぜ失敗したかは `KEYPIPE_FAILED_STAGE`（`erase` / `transform` / `output`）と `KEYPIPE_FAILED_STATUS`（終了コードの数字、`timeout`、`empty`、`ignored`、`stale`）で受ける。`KEYPIPE_APP` は今と同じ。
- `onFailure` は一段だけ。`onFailure` 自身が失敗しても次は無い。

使い分けの目安。同じ段の別の手段を試すならシェルの `||`。どの手段でも届かなかった文字を救うなら `onFailure`。

### (a) その場で翻訳。`claude -p` が失敗または時間切れなら別の API、それも駄目なら通知

```json
{
  "trigger": "@@@",
  "when": { "focus": "textField" },
  "transform": "perl -e 'alarm 15; exec @ARGV' claude -p 'Translate to English. Output only the translation.' || curl -sS -m 10 https://api.example.com/translate --data-urlencode \"text=$1\"",
  "output": "replaceInput"
}
```

段の内側の代替はシェルで書く。`claude -p` は stdin を食べるので、代替の `curl` は `$1` から読む。`perl -e 'alarm N; exec @ARGV'` は `verify.sh` の `cap` と同じ手口で、macOS 標準に `timeout` が無いことの回避。`onFailure` は省略なので既定の `notify`。

両方失敗したときの transcript。

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe transform exit 1
keypipe fail transform 1
keypipe apply notify "keypipe @@@: transform 1"
keypipe field "hello"
```

`perl` の alarm も効かずに固まったら、エンジンの固定の時間切れ（30 秒）で殺す。`transform exit` 行は出ない。

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe fail transform timeout
keypipe apply notify "keypipe @@@: transform timeout"
keypipe field "hello"
```

### (b) tmux へ送る。対象のセッションが無ければクリップボードに残して通知

```json
{
  "trigger": ";;;",
  "when": { "focus": "textField", "app": ["com.apple.TextEdit", "com.coteditor.CotEditor"] },
  "output": { "shell": "tmux new-window -t work -- claude \"$1\"" },
  "onFailure": { "shell": "printf %s \"$1\" | pbcopy; osascript -e \"display notification \\\"$KEYPIPE_FAILED_STAGE $KEYPIPE_FAILED_STATUS, copied\\\" with title \\\"keypipe\\\"\"" }
}
```

エディタで書いた依頼文を tmux の新しいウインドウの `claude` に渡す。`focus: textField` なので `$1` は欄の文字。ターミナルの中で打つ場合は改訂 3 のとおり `focus: any` になり `$1` は空なので、救う文字が無い。transcript（`work` が無い場合）。

```
keypipe matched ;;; rule 0
keypipe erase 3
keypipe output-shell exit 1
keypipe fail output 1
keypipe onfailure-shell exit 0
```

セッションが無ければ作る、なら `onFailure` ではなく `output.shell` の中で `tmux has-session -t work 2>/dev/null || tmux new-session -d -s work; tmux new-window -t work -- claude "$1"` と書く。これは同じ段の代替だから。

### (c) `replaceInput` の書き込みが無視されたら（Electron 系、未検証）、クリップボードに逃がす

```json
{
  "trigger": "@@@",
  "when": { "focus": "textField", "app": ["com.tinyspeck.slackmacgap"] },
  "transform": "claude -p 'Fix grammar. Output only the text.'",
  "output": "replaceInput",
  "onFailure": { "shell": "printf %s \"$1\" | pbcopy; osascript -e 'display notification \"result copied, press Cmd-V\" with title \"keypipe\"'" }
}
```

transcript（書き込み後の読み戻しが結果と違う場合）。

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe transform exit 0
keypipe fail output ignored
keypipe onfailure-shell exit 0
```

変換中に欄が閉じた（アプリ終了、ウインドウを閉じた）場合は `keypipe fail output stale`。同じ `onFailure` が走る。

改訂 3 のリスク欄にある「全選択してペースト」に自動で落とすのは、エンジンに組み込まず、望む人が `onFailure` に書く。

```json
"onFailure": { "shell": "printf %s \"$1\" | pbcopy; osascript -e 'tell application \"System Events\" to keystroke \"a\" using command down' -e 'tell application \"System Events\" to keystroke \"v\" using command down'" }
```

これは二つの未検証の前提に乗る。keypipe の子プロセスの `System Events` 打鍵が keypipe の Accessibility 許可で通るか。変換の数秒の間にフォーカスが元の欄から動いていないか。後者が崩れると別の欄を全部書き換える。だから既定にはせず、推奨例は (c) のクリップボード版にする。

### 一致しなかったとき（`nomatch`）

新しい仕組みは足さない。同じトリガーで `when` を省いたルールを最後に置けば、それが受け皿になる。設定順で最初に満たしたものが勝つ規則が既にある。

```json
{ "trigger": "@@@", "output": "notify" }
```

`focus: any` なので欄は読まず、テキスト欄ならトリガーだけ消す。

## Shape

### データ

```swift
// Config.swift. Rule gains one field. Output is reused, not a new enum.
struct Rule: Equatable {
    var trigger: String
    var when: When
    var transform: String?
    var output: Output
    var onFailure: Output   // default .builtin(.notify); .builtin(.replaceInput) rejected in loadConfig
}

// Engine.swift. Private to the fire sequence. Nothing outside Engine sees these.
enum Stage: String { case erase, transform, output }

enum FailStatus: Equatable, CustomStringConvertible {
    case exit(Int32)   // non-zero exit of transform or output.shell
    case timeout       // killed by the engine after shellTimeout
    case empty         // transform exited 0 with empty stdout (after the one-newline strip)
    case ignored       // AXValue write read back unchanged
    case stale         // field handle no longer valid
    var description: String { notImplemented() }   // "3", "timeout", "empty", "ignored", "stale"
}

struct Failure: Equatable {
    var stage: Stage
    var status: FailStatus
    var text: String   // what the rule was trying to deliver at that stage
}

// Desktop.swift. writeField now reports what happened. The read-back lives behind the port.
enum WriteResult: Equatable { case ok, ignored, stale }

protocol Desktop {
    func snapshot() -> Snapshot
    func erase(_ count: Int)
    func fieldText(_ f: Field) -> String
    /// Writes AXValue, then reads it back once. .ignored when the value differs from text.
    /// .stale when the element is gone (kAXErrorInvalidUIElement or the app quit).
    func writeField(_ f: Field, text: String) -> WriteResult
    func notify(_ text: String)
}

// Shell.swift. The one way keypipe runs a command (transform, output.shell, onFailure shell).
enum ShellStatus: Equatable { case exit(Int32), timeout }
struct ShellResult: Equatable { var status: ShellStatus; var stdout: String }

/// Fixed for every shell keypipe runs. Not a config key.
let shellTimeout: TimeInterval = 30

/// /bin/sh -c cmd keypipe input, input also on stdin and KEYPIPE_INPUT.
/// Spawns in its own process group and on timeout sends SIGTERM, then SIGKILL after 1 s,
/// to the whole group, so `claude` under `sh -c` dies too.
/// Strips exactly one trailing newline from stdout.
func runShell(_ cmd: String, input: String, env: [String: String], timeout: TimeInterval) -> ShellResult {
    notImplemented()
}
```

`text` が段ごとに何か。

| stage | いつ | `text` |
| --- | --- | --- |
| `erase` | Backspace 無視を検出して `AXValue` に書き戻したが、その書き込みも `ignored` / `stale` | トリガーを除いた欄の文字（変換に渡すはずだったもの） |
| `transform` | 非ゼロ終了、`timeout`、`empty` | 変換の入力 |
| `output` | `output.shell` の非ゼロ終了か `timeout`、`replaceInput` の `ignored` / `stale` | 変換の結果 |

### 流れ

```swift
// Engine.swift. The only place that knows the fire sequence.
struct Engine {
    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (_ cmd: String, _ input: String, _ env: [String: String]) -> ShellResult)
    mutating func key(_ c: Character)

    /// Steps 4-7 of revision 3. Returns the first failure, nil when delivered.
    /// Prints the existing transcript lines as it goes.
    private func deliver(_ rule: Rule, _ s: Snapshot) -> Failure? { notImplemented() }

    /// Prints `keypipe fail <stage> <status>`, then applies rule.onFailure once.
    /// .builtin(.notify) shows "keypipe <trigger>: <stage> <status>".
    /// .shell gets f.text plus KEYPIPE_FAILED_STAGE / KEYPIPE_FAILED_STATUS and prints
    /// `keypipe onfailure-shell exit <status>` (or `timeout`). Its own failure goes nowhere.
    private func fail(_ f: Failure, _ rule: Rule) { notImplemented() }
}
// key(): ... if let f = deliver(rule, snap) { fail(f, rule) }
```

失敗の扱いは `deliver` の戻り値一つと `fail` 一つに集まる。ルール選択（`select`）、`Desktop`、`TriggerMatcher` は失敗を知らない。

### 失敗点ごとの扱い

| # | 失敗点 | 扱い | ルールごと？ |
| --- | --- | --- | --- |
| 1 | `composing` | 失敗ではない。改訂 3 のまま | 固定 |
| 2 | `nomatch` | 失敗ではない。受け皿は `when` を省いた最後のルール | 既存の設定順で書ける |
| 3 | 読み戻しの期限（200 ms）切れ | これが「Backspace が無視された」の観測そのもの。書き戻しへ進む。書き戻しも `ignored` / `stale` なら `fail erase` | `onFailure` |
| 4 | `transform` 非ゼロ、ハング | `fail transform <n>`。固定 30 秒で殺して `fail transform timeout` | `onFailure`（時間は固定） |
| 5 | `transform` が 0 で空出力 | 失敗 `empty`。`replaceInput` で欄を空にする事故を防ぐ | `onFailure` |
| 6 | `output.shell` 非ゼロ | `fail output <n>`。既定は通知（今はログだけ） | `onFailure` |
| 7 | `replaceInput` の書き込み無視 | `writeField` の読み戻しで `ignored` | `onFailure` |
| 8 | 欄のハンドルが無効 | `writeField` が `stale` | `onFailure` |
| 9 | `output.shell` のハング | 固定 30 秒で殺して `fail output timeout` | `onFailure`（時間は固定） |

新しい transcript 行は二つ。どちらも追加で、既存の行の形は変えない。

| 行 | 意味 |
| --- | --- |
| `keypipe fail <stage> <status>` | ルールが届けずに終わった。`status` は数字か `timeout` / `empty` / `ignored` / `stale` |
| `keypipe onfailure-shell exit <status>` | `onFailure` のシェルが終わった。`status` は数字か `timeout` |

`onFailure` が組み込みなら既存の `keypipe apply notify <json>` が出る。`none` なら何も出ない。時間切れのときは `transform exit` / `output-shell exit` 行を出さない（終了コードが無いので）。

FakeDesktop の `--context` に一つ足す。`"write": "ok" | "ignored" | "stale"`（省略は `ok`）。bool を二つ足すと「無視かつ無効」という意味の無い組が書けるので、文字列一つにする。

### 次の後始末を足す人へ

- 新しい後始末（別の通知先、ログ、リトライ、別の翻訳器）は設定の `onFailure` か `||` で書く。Swift は触らない。
- 新しい種類の失敗（例えば欄のハンドルは有効だが別のウインドウに移った）を見つけたら、`FailStatus` に case を一つ、それを返す場所（`Desktop` の戻り値か `deliver`）を一つ、`SKILL.md` の status 一覧に一語足す。`select`、`TriggerMatcher`、`Config` は触らない。`switch` の網羅性検査が `description` の書き漏れを止める。

### 判断と原則

- 失敗の行き先に新しい型を作らず `Output` を再利用し、`replaceInput` を `loadConfig` で弾く。改訂 3 が「`replaceInput` は `focus: textField` だけ」を入れ子の列挙でなく検査一つにしたのと同じ流儀。laziness-protocol と、コードベースの支配的なパターンに従う判断連鎖による。
- `onFailure` はシェルと同じ stdin / `$1` / 環境変数で受ける。失敗の情報を渡す二つ目の経路（JSON の失敗レコードを stdin に流す等）を作らない。
- 段の内側の代替（`claude -p` が駄目なら `curl`）に設定キーを足さない。`||` と二通りの書き方になる。
- 書き込みの読み戻しは `MacDesktop.writeField` の中に置き、`Engine` は `WriteResult` だけを見る。AX の値比較を境界の外に漏らさない。boundary-discipline による。
- 時間切れは固定 30 秒の一つの値で、全シェルに同じ。ルールごとの値に実例が無い。短くしたい人は `perl -e 'alarm N; exec @ARGV'` か `curl -m` で中から縮められる。長くする手段だけが無い。
- `onFailure` は一段。連鎖を許すと失敗の木を持つことになり、それはパイプライン枠組みの入口になる。

### 意図的にやらないこと

- ステップ列、段ごとの `fallback` キー、リトライ回数、指数バックオフ。リトライはシェルで書ける（`for i in 1 2 3; do cmd && break; sleep 1; done`）。
- 全選択してペーストの組み込み。上の (c) のとおり設定で書け、未検証の前提が二つ乗る。
- ルールごとの時間切れ。
- `KEYPIPE_FAILED_STDERR`。`claude -p` の失敗理由を通知に出したい実例が出たら足す。今は transform の stderr を keypipe の stderr に流すだけ。
- 動的プラグイン。制約は変えない。

## Synthesis decision

arena が埋める。

## Tradeoffs accepted

- `onFailure` と `output.shell` の `||` が重なる場面（シェルの非ゼロ終了）を受け入れる。代わりに、シェルから見えない失敗（書き込み無視、欄の消失、時間切れの kill、空出力）も同じ一つのキーで受けられる。目安は「同じ段の代替は `||`、届かなかった文字の救済は `onFailure`」。
- `output.shell` の失敗が既定で通知されるようになる（今はログだけ）。代わりに「黙って届かない」が無くなり、全段で既定の振る舞いが一つになる。静かにしたいルールは `"onFailure": "none"`。
- 時間切れ 30 秒を全ルールで固定にする。代わりに設定キーが増えない。30 秒より長い変換は書けない。
- `transform` の空出力を失敗とみなす。代わりに `replaceInput` が欄を消す事故が無くなる。意図して欄を空にするルールは書けない（実例が無い）。
- 時間切れの検証項目は本物の 30 秒を待つので、`verify.sh` が 30 秒ほど遅くなる。代わりにテスト専用の上書き環境変数を作らない。時間切れの仕組み自体は `runShell` の単体テストで短い値を渡して速く確かめる。
- `onFailure` 自身の失敗は transcript に出るだけで、利用者には届かない。

## Alternatives considered

- 段ごとの `fallback`（`transform: {run, fallback}`、`output: {shell, fallback}`）。段の数だけキーが増え、シェルの `||` と二通りの書き方になる。シェルから見えない失敗（書き込み無視など）は結局どの段の `fallback` に属すかを決める規則が要る。表面が大きく、隠すものが少ない。
- 失敗を型付きの後始末の列挙で書く（`"onFailure": "clipboard"`、`"pasteFallback"` など）。種類を足すたびに Swift の編集が要り、「設定の編集だけで新しい後始末」が崩れる。`clipboard` は改訂 3 で `pbcopy` に寄せて削った組み込みの復活になる。
- `steps: [...]` と `catch`。改訂 2 で退けたステップ列の再来で、シェルのパイプと二通りになる。
- `onFailure` を `output` と別の列挙 `Fallback { notify, none, shell }` にして `replaceInput` を型で表せなくする。型の規律としては強いが、JSON の形が同じ二つの型を持つことになり、改訂 3 の検査一つの流儀からも外れる。差は `loadConfig` の検査 1 行と R2 の 1 項目。

## Open questions and risks

- 30 秒で足りるか。`claude -p` の長文翻訳で 30 秒を超える実測はあるか。超えるなら値を上げるか、ルールごとにするか。
- Electron 系の `AXValue` 書き込みは本当に無視されるか、無視されたとき読み戻しで判別できるか（書いた値が読めてしまうのに画面は変わらない、だと `ignored` にならない）。未検証。
- `stale` を AX のエラーで判別できるか。ウインドウを閉じた後の `AXUIElement` への書き込みが `kAXErrorInvalidUIElement` を返すか、黙って成功するか。未検証。
- `output.shell` の失敗を既定で通知に変えることを受け入れるか。今の利用者に「通知が増えた」と見えるか。
- keypipe の子プロセスからの `System Events` 打鍵（(c) のペースト版）が keypipe の Accessibility 許可で通るか。未検証。推奨例はクリップボード版。
- `empty` を失敗にする判断で困るルールがあるか。

## 改善の順序（機能より先に構造）

各段は `swift test` か `verify.sh --no-live` で終える。段 1 から 5 は利用者から見える振る舞いを増やさない（旧スキーマの撤去は振る舞いの削除）。機能は段 6 から。

1. **消す。** `log` アクションと `KeypipeConfig.logPath` を消す。`Actions.swift` の `log` 分岐、`Config.swift` の `"log"` 検査、`main.swift` の `logPath` 引き回し、`Tests/keypipeTests/ActionsTests.swift` の log の項目。確認は `swift test`。
2. **matcher を一致の報告だけにする。** `TriggerMatcher` は `[String]` を受け、`feed` は一致したトリガー文字列を返す。`TriggerRule` と `contextMatches` 呼び出しを消す。`Sources/keypipe/Trigger.swift`、`Tests/keypipeTests/TriggerTests.swift`、`TriggerExhaustiveTests.swift`。確認は `swift test` と `verify-keypipe-trigger`（最長一致と 64 文字上限が変わらない）。
3. **シェル実行を一つにする。** `Sources/keypipe/Shell.swift` に `runShell(cmd, input:, env:, timeout:) -> ShellResult` を作る。`$1`、stdin、`KEYPIPE_INPUT`、末尾改行一つの除去、プロセスグループでの時間切れ。`Actions.swift` の `shell` 分岐はこれを呼ぶだけにする。テストは新規 `Tests/keypipeTests/ShellTests.swift`（`$1` と stdin、改行除去、`timeout: 0.2` で `sleep 5` が `.timeout`、子の `sleep` も死ぬ）。確認は `swift test`。失敗の仕組みの半分（時間切れ）はここで入るが、まだ誰も `.timeout` を受け取らない。
4. **新スキーマと純粋な選択。** `Config.swift` を改訂 3 のスキーマ（`trigger` / `when` / `transform` / `output`、未知キーの拒否、R2 の理由文字列）に置き換え、`Context.swift` の `MatchContext` を消して `When` / `Snapshot` / `matches` / `select` にする。`Tests/keypipeTests/ConfigTests.swift`、`ContextTests.swift`。`config.example.json` も新スキーマへ。確認は `swift test`。
5. **境界と発火手順。** `Sources/keypipe/Desktop.swift`（`writeField` は最初から `WriteResult` を返す）、`FakeDesktop.swift`（`--context`、`write` キーは `ok` 固定でよい）、`Engine.swift`（`deliver` が `Failure?` を返す形で書き、失敗時は改訂 3 のとおり `notify` だけ）。`Actions.swift` を消す。`main.swift` を Engine 配線と `--context` に。`ActionsTests.swift` を消し、Engine の単体テストを `Tests/keypipeTests/EngineTests.swift` に。確認は `verify.sh --no-live` の R1、R2a-g、R3-R8 がすべて PASS。ここが構造改善の完了点。

ここから機能。

6. **失敗時の受け口。** `Config.swift` に `onFailure`（既定 `notify`、`replaceInput` を拒否）。`Engine.fail` と `keypipe fail` / `keypipe onfailure-shell exit` 行。`FakeDesktop` の `write: ignored | stale`。`transform` の `empty`。`verify.sh` と `SKILL.md` に項目を足す。
   - R2h `onFailure: "replaceInput"` は exit 1 と `invalid config: onFailure cannot be replaceInput`。
   - R9a `transform: "exit 3"`、`onFailure` シェルが副作用ファイルに `$1|$KEYPIPE_FAILED_STAGE|$KEYPIPE_FAILED_STATUS` を書く。`hello|transform|3` と `keypipe fail transform 3`、欄は `hello`。
   - R9b `transform: "sleep 60"`。`keypipe fail transform timeout`、`transform exit` 行が無い、欄は `hello`。`cap 45` で 30 秒待つ。
   - R9c `transform: "true"`。`keypipe fail transform empty`、`apply replaceInput` 無し、欄は `hello`。
   - R9d `output: {"shell":"exit 1"}`、既定の `onFailure`。`keypipe fail output 1` と `keypipe apply notify`。
   - R9e `write: ignored`、`replaceInput`、`onFailure` シェルの副作用ファイルが変換結果 `HELLO`。`keypipe fail output ignored`。
   - R9f `write: stale`。`keypipe fail output stale`。
   - R9g `onFailure: {"shell":"exit 4"}` で `keypipe onfailure-shell exit 4` が出て、その後に `fail` 行が二度目に出ない（一段だけ）。
   - 既存の R5c（失敗した変換で通知、欄はそのまま）は変えずに PASS し続ける。
   確認は `verify.sh --no-live` 全項目。
7. **実機の境界。** `MacDesktop.swift`（AX、Backspace の印、読み戻しの待ち、`writeField` の読み戻し）と `MacKeyTap.swift`（本物の CGEventTap、直列キュー）。確認は `verify.sh` の M0-M4。
8. **実機での失敗。** `stale` の実測（TextEdit で変換中に書類を閉じる。`transform: "sleep 3"`）。Electron 系 1 本で `ignored` の実測。結果を `verification-plan.md` に記録し、判別できない場合は `FailStatus` の意味をそこで直す。

段 6 を段 7 より先にするのは、失敗の扱いが偽物の境界だけで全部確かめられるから。段 7 の実機作業の間、失敗の行が出るので原因が読める。

## Next implementation step

段 1。`Actions.swift` の `log` 分岐と `KeypipeConfig.logPath` を消し、`swift test` を通す。
