# 候補 2: 失敗の領域を型にする（段ごとの結果、段に紐づく代替、純粋な reducer）

利用者の目的。keypipe は macOS の常駐プロセスで、テキスト欄でトリガーを打つと欄の文字を設定した変換に通し、設定した送り先へ渡す。振る舞いは JSON の設定一つで書く。今回の要望は三つ。段が失敗したときの代替をルールごとに書けること。それを疎結合に足し、次の代替を足しても中核を触らずに済むこと。現 MVP の構造を先に直し、その後で機能を実装する計画。

この席の方針。発火手順を型付きの段に分け、段ごとに型付きの結果を持たせる。ルールごとの代替は段をキーにした値にする。代替は「失敗した段を、その段と同じ語彙で書いた別の値に差し替える」と定義する。新しい語彙は作らない。Engine は (段, 結果) から次の作用を返す純粋な reducer にし、Desktop とシェルは注入する作用として外に置く。

## 1. 失敗点の分類（誰が観測できるか）

代替の語彙を決める前に、九つの失敗点を「シェルの中で見えるか、エンジンにしか見えないか」で分けた。「シェルで書けることに二通り目を作らない」の制約はここで効く。

| # | 失敗点 | 誰が見えるか | 扱い | 理由 |
| --- | --- | --- | --- | --- |
| 1 | `composing` | エンジン | 固定。発火しない | 失敗ではない。改訂 3 のまま |
| 2 | `nomatch` | エンジン | **新しいキーは作らない**。同じトリガーで `when` を空にしたルールを末尾に置く | 設定順で最初に満たしたルールが勝つので、末尾の受け皿ルールが「どれも満たさなかったとき」をすでに表す。コード 0 行 |
| 3 | 消去の読み戻しが期限切れ | エンジン | 固定（失敗ではない） | 改訂 3 の手順 5 では、期限内に値が変わらないこと自体が「Backspace 無視」の合図で、書き戻しへ進む。本当の失敗は下の 3' |
| 3' | 書き戻しも無視された、末尾にトリガーが無い、欄が消えた | エンジン | 固定。欄が消えたら発火を終える。それ以外は続行し `erase-failed` を出す | ルールごとに選びたい値が無い（下記）。危ない選択肢（盲目の再書き戻し）は設定から選べないようにする |
| 4 | `transform` 非ゼロ終了 | シェル**と**エンジン | ルールごと `onFail.transform`。既定は通知 | シェルの `||` でも書ける。重なりは「受け入れた取引」に書いた |
| 4' | `transform` 期限切れ | **エンジンだけ** | ルールごと `onFail.transform`。期限は設定の `shellTimeout` | エンジンが `sh -c` のプロセスグループを殺すので `||` の右辺は走らない。標準の macOS に `timeout(1)` は無い（この Mac の `timeout` は `/opt/homebrew/bin`、`/usr/bin/timeout` は無い。実測） |
| 5 | `transform` が 0 で終わり出力が空 | エンジン | 固定で失敗に分類し、その後はルールごと `onFail.transform` | 空を `replaceInput` に渡すと利用者の文を消す。データ損失を既定にしない |
| 6 | `output.shell` 非ゼロ終了 | シェルとエンジン | ルールごと `onFail.output`。既定は今の「記録だけ」 | 4 と同じ重なり |
| 9 | `output.shell` 期限切れ | エンジンだけ | ルールごと `onFail.output`。期限は `shellTimeout` | 4' と同じ |
| 7 | `replaceInput` の書き込みが無視された | **エンジンだけ** | ルールごと `onFail.output`。既定は結果を通知 | 書いた後の読み戻しでしか分からない。シェルには書けない |
| 8 | 欄のハンドルが古い（アプリ終了、窓を閉じた） | エンジンだけ | 7 と同じ扱い。今フォーカスしている別の欄には決して書かない | 改訂 3 の「捕まえたハンドルへ書く」を守る |
| - | 代替そのものの失敗 | エンジン | 固定。通知して終わる | 代替の代替は型で書けない（下記）。一回の発火で走るシェルは高々 4 本、所要時間は `4 × shellTimeout + 消去の期限` で上が決まる |

3' にルールごとの値を置かない理由。選べそうな値は「中止」と「続行」だけで、続行が常に正しい。`replaceInput` のルールは欄全体を書き換えるので、トリガーが残っていても結果に混ざらない（入力の文字列からはトリガーを取り除く）。送り先がシェルのルールは、欄に `@@@` が見えたまま残るだけで、利用者の文字は消えない。中止すると、遅い `claude -p` の結果ごと失う。だから固定の続行にした。結果として、この席の題にある「`focus: any` のルールに消去の代替」は書けない。**どのルールでも `onFail.erase` は `unknown key erase` で拒否する**。

## 2. Usage（利用者の見え方）

### README の抜粋

`onFail` はルールの段をキーにした差し替えである。キーは段の名前、値はその段と同じ書き方の値。

- `onFail.transform` は `transform` と同じく文字列のシェルコマンド。`transform` が非ゼロで終わったとき、期限を過ぎたとき、空を出したときに、**同じ入力**で一度だけ走る。その標準出力が結果になり、本来の `output` へ渡る。
- `onFail.output` は `output` と同じく `"notify"` / `"none"` / `"replaceInput"` / `{ "shell": "..." }`。本来の送り先が失敗したときに、**同じ結果**を受けて一度だけ走る。
- 代替の環境変数 `KEYPIPE_FAILURE` に失敗の理由が入る。値は `exit <n>` / `timeout` / `empty` / `ignored` / `gone`。理由で分けたいときはシェルの中で分ける。
- 代替が失敗したら、keypipe は通知して終わる。代替の代替は書けない。
- `onFail` が無いとき。変換の失敗は通知（今と同じ）。`replaceInput` の失敗は結果の文字を通知（文字を失わない）。`output.shell` の失敗は記録だけ（今と同じ）。
- 最上位の `shellTimeout`（秒、既定 30）は、変換、`output.shell`、それぞれの代替、すべてのシェルに効く期限。過ぎたらプロセスグループごと止める。
- 「どのルールも満たさなかったら X」は、同じトリガーで `when` を書かないルールを末尾に置く。

設定で拒否するもの（`invalid config: <理由>`、理由は文字どおり照合される）。

| 設定 | 理由 |
| --- | --- |
| `transform` が無いのに `onFail.transform` | `onFail.transform requires transform` |
| `output` が `"none"` か `"notify"` なのに `onFail.output` | `onFail.output requires an output that can fail` |
| `focus: any` で `onFail.output: "replaceInput"` | `output replaceInput requires focus textField`（`output` と同じ検査を通る） |
| `onFail.erase` などの未知の段 | `unknown key erase` |
| `onFail.transform: ""` | `empty transform`（`transform` と同じ検査） |
| `onFail.output: {"shell": ""}` | `empty output.shell`（同上） |
| `shellTimeout` が正の数でない | `shellTimeout must be positive` |

### (a) その場で翻訳し、`claude -p` が失敗か期限切れなら別の API に落とす

```json
{
  "shellTimeout": 20,
  "rules": [
    {
      "trigger": "@@@",
      "when": { "focus": "textField" },
      "transform": "claude -p 'Translate to English. Output only the translation.'",
      "output": "replaceInput",
      "onFail": {
        "transform": "curl -sS -m 5 https://api.example.com/translate --data-urlencode text@-"
      }
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

両方とも失敗したとき（`claude -p` が 1 で終わり、`curl` も 6 で終わる）。欄は消去後の `こんにちは` のまま。

```
keypipe matched @@@ rule 0
keypipe erase 3
keypipe transform exit 1
keypipe fallback transform exit 6
keypipe apply notify "@@@ transform failed: exit 6"
```

`claude -p` が 0 で終わり何も出さないとき。欄を空にせず、代替へ進む。

```
keypipe transform exit 0
keypipe transform empty
keypipe fallback transform exit 0
keypipe apply replaceInput "Hello"
```

### (b) 欄の文字を tmux へ送り、宛先が無ければクリップボードに残す

`focus: any` のルールは改訂 3 で入力が空になるので、欄の文字を送る例は `focus: textField` にする。

```json
{
  "trigger": ";;t",
  "when": { "focus": "textField" },
  "output": { "shell": "tmux send-keys -t work:claude -l -- \"$1\" && tmux send-keys -t work:claude Enter" },
  "onFail": {
    "output": { "shell": "pbcopy" }
  }
}
```

セッション `work` が無いとき（`tmux send-keys` は `can't find session` で 1 を返す）。欄は `;;t` が消えた本文のまま。

```
keypipe matched ;;t rule 1
keypipe erase 3
keypipe output-shell exit 1
keypipe fallback output-shell exit 0
```

tmux サーバが固まって返らないときは `keypipe output-shell timeout 20` の後に同じ代替が走る。シェルの `|| pbcopy` で書くと、こちらの場合だけ代替が走らない。

### (c) `replaceInput` の書き込みが無視されたら、結果をクリップボードへ

Electron 系の欄は `AXValue` の書き込みを無視することがある（未検証のリスク）。

```json
{
  "trigger": "@@e",
  "when": { "app": ["com.tinyspeck.slackmacgap"], "focus": "textField" },
  "transform": "claude -p 'Translate to English. Output only the translation.'",
  "output": "replaceInput",
  "onFail": { "output": { "shell": "pbcopy" } }
}
```

書き込み後の読み戻しが一致しないとき。`apply replaceInput` は確かめた後にだけ出るので、ここでは出ない。

```
keypipe matched @@e rule 2
keypipe erase 3
keypipe transform exit 0
keypipe apply-failed replaceInput ignored
keypipe fallback output-shell exit 0
```

変換の間に窓を閉じたとき。今フォーカスしている欄には書かない。

```
keypipe transform exit 0
keypipe apply-failed replaceInput gone
keypipe fallback output-shell exit 0
```

`onFail` を書かなければ、最後の行は `keypipe apply notify "Hello"` になる。

### どれも満たさないときの受け皿（コード 0 行）

```json
{ "trigger": "@@@", "when": { "focus": "textField" }, "transform": "...", "output": "replaceInput" },
{ "trigger": "@@@", "output": "notify" }
```

二つ目は `focus: any`、全アプリ。一つ目を満たさない状況では二つ目が `matched @@@ rule 1` になる。`nomatch` は出なくなる。

### keypipe 自身のコードでの呼び出し

```swift
// main.swift, --smoke-feed with --context
let desktop = try FakeDesktop(contextPath: contextPath)
var engine = Engine(config: config, desktop: desktop, shell: runShell, emit: { print($0); fflush(stdout) })
for c in feed { engine.key(c) }
print(Line.field(desktop.text))

// Tests: the whole failure policy without a desktop or a process
let s0 = start(rule, index: 0, Snapshot(app: nil, focus: .text, field: Field(token: 1)), trigger: t)
guard case .erase(_, let k0) = s0.next else { return XCTFail() }
let s1 = resume(k0, .cleared(input: "hello"))
guard case .shell(let req, let k1) = s1.next else { return XCTFail() }
let s2 = resume(k1, .timedOut)
XCTAssertEqual(s2.lines, [.shell(.transform, .primary, .timedOut(seconds: 20))])
guard case .shell(let fb, _) = s2.next else { return XCTFail() }
XCTAssertEqual(fb.command, rule.transform!.onFail)
XCTAssertEqual(fb.input, req.input)          // the fallback sees the same input
XCTAssertEqual(fb.env["KEYPIPE_FAILURE"], "timeout")
```

## 3. 型の下書きと関数の形

### Config.swift（JSON の境界。ここより内側は構築時点で正しい）

```swift
/// 1...triggerMaxBuffer characters.
struct Trigger: Hashable { let text: String }
/// Non-empty /bin/sh script.
struct ShellCommand: Equatable { let script: String }

/// A primary value and the value that replaces it once when it fails.
/// `onFail` has type Value, not Guarded<Value>: a fallback of a fallback has no representation.
struct Guarded<Value: Equatable>: Equatable {
    let primary: Value
    let onFail: Value?
}

/// Sinks that never touch the originating field.
enum Sink: Equatable { case none, notify, shell(ShellCommand) }

/// What a textField rule may deliver to. Only this type can hold replaceInput.
enum FieldSink: Equatable { case replaceInput, elsewhere(Sink) }

/// The rule's focus scope carries the outputs it allows, primary and fallback alike.
enum Scope: Equatable {
    case textField(Guarded<FieldSink>)   // reads the field, may write it back
    case any(Guarded<Sink>)              // input is "", never reads or writes the field
}

struct Rule: Equatable {
    let trigger: Trigger
    let apps: Set<String>?                  // nil = any app
    let transform: Guarded<ShellCommand>?   // nil = identity; onFail cannot exist without it
    let scope: Scope
}

struct KeypipeConfig: Equatable {
    let rules: [Rule]
    let shellTimeout: Duration              // default .seconds(30)
}

/// Rejects unknown keys at every level, onFail included. One parser per stage
/// (parseTransform, parseOutput) is called for both the primary and the onFail value,
/// so every rule about a stage's value is checked once and holds for its fallback.
func loadConfig(path: String) throws -> KeypipeConfig { notImplemented() }
```

### Context.swift（改訂 3 のまま）

```swift
enum Focus: Equatable { case nothing, text, composing }
struct Field: Equatable { let token: Int }
struct Snapshot: Equatable { let app: String?; let focus: Focus; let field: Field? }
func select(_ rules: [Rule], trigger: Trigger, _ s: Snapshot) -> Int? { notImplemented() }
```

### Fire.swift（新規。失敗の領域と純粋な reducer。I/O なし）

```swift
enum Stage: Equatable { case transform, output }
enum Attempt: Equatable { case primary, fallback }

// One outcome type per effect. The interpreter produces them; the reducer consumes them.
enum EraseOutcome: Equatable {
    case cleared(input: String)          // Backspace removed the trigger (or focus-any keys sent, input "")
    case rewritten(input: String)        // Backspace ignored, AXValue rewritten (TextEdit)
    case stillVisible(input: String, EraseFailure)
    case gone                            // field handle dead before it was read
}
enum EraseFailure: String, Equatable { case rewriteIgnored = "rewrite-ignored", triggerAbsent = "trigger-absent" }
enum ShellOutcome: Equatable { case exited(Int32, stdout: String), timedOut(seconds: Int) }
enum WriteOutcome: Equatable { case written, ignored, gone }

/// Why a stage failed. Crosses into the fallback's env (KEYPIPE_FAILURE) and the transcript,
/// so both read the same `token`.
enum Failure: Equatable {
    case exit(Int32), timeout, empty, ignored, gone
    var token: String { notImplemented() }   // "exit 3" | "timeout" | "empty" | "ignored" | "gone"
}

struct ShellRequest: Equatable {
    let command: ShellCommand
    let input: String
    let env: [String: String]                // KEYPIPE_INPUT, KEYPIPE_APP, KEYPIPE_FAILURE on fallbacks
    let timeout: Duration
}
enum EraseRequest: Equatable {
    case field(Field, Trigger)               // read, Backspace, wait, read back, rewrite if ignored
    case keys(Int)                           // focus-any rule on a text focus: Backspace only, no read
}

/// The fire in progress. Opaque to the interpreter; it only hands it back.
struct FireState: Equatable {
    let rule: Rule
    let index: Int
    let snapshot: Snapshot
    let shellTimeout: Duration
    // input once erased, result once transformed. notImplemented details.
}
struct AfterErase: Equatable { let fire: FireState }
struct AfterShell: Equatable { let fire: FireState; let stage: Stage; let attempt: Attempt }
struct AfterWrite: Equatable { let fire: FireState; let text: String; let attempt: Attempt }

/// Each effect carries the continuation that consumes its outcome. The overloads of
/// `resume` below accept only the matching outcome type, so feeding a ShellOutcome to an
/// erase continuation does not compile. No closures: every Step is Equatable and table-testable.
enum Next: Equatable {
    case erase(EraseRequest, AfterErase)
    case shell(ShellRequest, AfterShell)
    case write(Field, String, AfterWrite)
    case notify(String)                      // terminal; notify cannot fail
    case end
}
struct Step: Equatable { let lines: [Line]; let next: Next }

func start(_ rule: Rule, index: Int, _ s: Snapshot, trigger: Trigger, shellTimeout: Duration) -> Step { notImplemented() }
func resume(_ k: AfterErase, _ o: EraseOutcome) -> Step { notImplemented() }
func resume(_ k: AfterShell, _ o: ShellOutcome) -> Step { notImplemented() }
func resume(_ k: AfterWrite, _ o: WriteOutcome) -> Step { notImplemented() }

/// The transcript contract. One enum, one rendering; verify.sh matches the rendered strings.
enum Line: Equatable, CustomStringConvertible {
    case matched(Trigger, rule: Int), nomatch(Trigger), composing(Trigger)
    case erase(Int), eraseRewrite, eraseFailed(EraseFailure)
    case shell(Stage, Attempt, ShellOutcome)   // "transform exit 3", "fallback output-shell timeout 20"
    case transformEmpty(Attempt)               // "transform empty", "fallback transform empty"
    case apply(String, String)                 // "apply replaceInput \"HELLO\"", only after readback agrees
    case applyFailed(Failure)                  // "apply-failed replaceInput ignored|gone"
    case field(String)                         // FakeDesktop only, printed by main
    var description: String { notImplemented() }
}
```

reducer の要の分岐（`resume(AfterShell, ShellOutcome)`）。疑似コード。

```swift
// TODO pseudocode
// classify: .exited(0, out) -> out minus one trailing "\n"; empty -> .empty (transform only)
//           .exited(n, _) -> .exit(n); .timedOut -> .timeout
// (transform, primary,  ok)      -> deliver(out) via scope's primary output
// (transform, primary,  failure) -> rule.transform.onFail ?
//                                     .shell(same input, KEYPIPE_FAILURE=failure.token, .fallback)
//                                   : .notify("<trigger> transform failed: <token>")
// (transform, fallback, ok)      -> deliver(out) via primary output
// (transform, fallback, failure) -> .notify("<trigger> transform failed: <token>")
// (output,    primary,  ok)      -> .end
// (output,    primary,  failure) -> onFail.output ? deliverFallback(result, failure) : .end (log only)
// (output,    fallback, any)     -> failure ? .notify(result) : .end
```

`erase <count>` と `erase-rewrite` は `start` ではなく `resume(AfterErase, ...)` が `cleared` / `rewritten` を受けたときに出す。`gone` で `erase 3` と書かないため。`resume(AfterWrite, WriteOutcome)` も `attempt` で同じ表を引き（`fallback` の失敗は通知で終わる）、`ignored` / `gone` は `onFail.output` へ、無ければ `.notify(result)`。`onFail.output` が `replaceInput` で `gone` の場合（送り先がシェルで、代替が欄への書き戻し）は、同じ古いハンドルへ書いて `gone` が返り、通知で終わる。今のフォーカスへは書かない。

### Desktop.swift（境界のポート。原始的な操作だけ）

```swift
protocol Desktop {
    func snapshot() -> Snapshot
    func backspace(_ count: Int)                    // tagged with keypipe's eventSourceUserData
    func text(_ f: Field) -> String?                // nil: handle is dead
    func setText(_ f: Field, _ s: String) -> Bool   // false: handle is dead
    func notify(_ s: String)
}

/// --context JSON. Existing keys unchanged; two optional keys are new:
///   {"app":..,"focusIsTextField":bool,"fieldText":..,"composing":bool?,"ignoresBackspace":bool?,
///    "ignoresWrite":bool?,      // setText returns true but text() keeps the old value  -> WriteOutcome.ignored
///    "fieldGoneAfter":"erase"?} // text()/setText() report a dead handle after the erase -> WriteOutcome.gone
final class FakeDesktop: Desktop {
    init(contextPath: String) throws { notImplemented() }
    var text: String { notImplemented() }
}
```

### Engine.swift（解釈器。作用を実行し、結果を reducer に返す）

```swift
struct Engine {
    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (ShellRequest) -> ShellOutcome, emit: @escaping (Line) -> Void) { notImplemented() }
    /// Feeds the matcher. On a hit: snapshot, composing gate, select, then drive(start(...)).
    mutating func key(_ c: Character) { notImplemented() }
}

/// The only loop. Prints each step's lines, performs its effect, resumes.
private func drive(_ first: Step, _ d: Desktop, _ shell: (ShellRequest) -> ShellOutcome, _ emit: (Line) -> Void) {
    // var step = first
    // loop: step.lines.forEach(emit); switch step.next {
    //   .erase(r, k)      -> step = resume(k, performErase(r, d))
    //   .shell(r, k)      -> step = resume(k, shell(r))
    //   .write(f, t, k)   -> step = resume(k, performWrite(f, t, d))
    //   .notify(t)        -> d.notify(t); emit(.apply("notify", t)); return
    //   .end              -> return }
}

/// Revision 3 step 5, written once over Desktop primitives so Mac and Fake cannot drift.
/// Read, Backspace, poll text() until it changes or ~200 ms pass, read again; unchanged means
/// ignored -> strip trailing trigger, setText, read back.
func performErase(_ r: EraseRequest, _ d: Desktop) -> EraseOutcome { notImplemented() }
/// setText false -> .gone; text() != s -> .ignored; else .written.
func performWrite(_ f: Field, _ s: String, _ d: Desktop) -> WriteOutcome { notImplemented() }
```

### Shell.swift（`Actions.swift` を置き換える）

```swift
/// /bin/sh -c <script> keypipe <input>, input also on stdin. posix_spawn with
/// POSIX_SPAWN_SETPGROUP so the deadline kills the whole group (sh, claude, curl);
/// Foundation's Process.terminate() would kill only sh. SIGTERM, then SIGKILL after 1 s.
func runShell(_ r: ShellRequest) -> ShellOutcome { notImplemented() }
```

## 4. モジュール図（Sources/keypipe）

| ファイル | 持つもの | 改訂 3 からの差 |
| --- | --- | --- |
| `Config.swift` | `Trigger`, `ShellCommand`, `Guarded`, `Sink`, `FieldSink`, `Scope`, `Rule`, `KeypipeConfig`, `loadConfig` | `When`+`Output` を `Scope` に。`onFail`、`shellTimeout`、理由 4 つ追加 |
| `Context.swift` | `Focus`, `Field`, `Snapshot`, `select` | 同じ |
| `Fire.swift` | 結果の型、`Failure`, `Next`, `Step`, `start`/`resume`, `Line` | 新規。失敗の方針はすべてここ |
| `Engine.swift` | `TriggerMatcher` の保持、選択、`drive`, `performErase`, `performWrite` | 手順 1-7 の制御が `Fire.swift` へ移り、ここは解釈器だけ |
| `Shell.swift` | `runShell`（プロセスグループと期限） | `Actions.swift` を置き換え |
| `Desktop.swift` | `Desktop`, `FakeDesktop` | 原始操作 5 つ。`--context` に 2 キー |
| `MacDesktop.swift` | AX と CGEvent | 原始操作 5 つの実装だけ。消去の手順は持たない |
| `Trigger.swift` | `TriggerMatcher`（一致したトリガーを返す） | 同じ |
| `MacKeyTap.swift`, `main.swift` | tap、配線、`--context`、`--probe` | 同じ |

一つの発火を追うのに読むのは `Engine.swift`（どこで止まるか）、`Fire.swift`（次に何をするか）、`Desktop.swift`（欄に何をするか）の 3 ファイル。

## 5. Rationale

### Problem

発火手順は七段あり、そのうち消去、変換、送り先の三段が失敗する。今の方針は「変換が非ゼロなら通知」の一行だけで、期限切れ、空の出力、書き込み無視、古いハンドル、`output.shell` の失敗は未定義。とくに期限が無いので、固まった `claude -p` が直列の発火キューを永久に止める。利用者はこれをルールごとに書き分けたい。持ち込んだ制約は、設定が唯一の宣言面であること、プラグイン実行系を作らないこと、`Desktop` が唯一の AX と CGEvent の境界であること、出力行と拒否理由は足すだけの契約であること、シェルで書けることに二通り目を作らないこと。

### Shape

データの形は三つの型が一つの純粋関数で出会う形にした。設定側の `Guarded<Value>`（本来の値と、失敗したときに一度だけ差し替える値）。作用側の段ごとの結果（`EraseOutcome`, `ShellOutcome`, `WriteOutcome`）。その二つを受けて次の作用を返す `start` / `resume`。

**代替は段の語彙で書く。** `onFail.transform` は `transform` と同じ型、`onFail.output` は `output` と同じ型で、同じ解析関数を通る。代替専用の語彙（`retry`、`fallbackTo`、種類名の表）は作らない。送り先に新しい種類が増えれば、そのまま代替にも使える。疎結合の中身はこれで、代替のために増える Swift は無い。model-the-domain による。

**書けない組み合わせは型で消す。** type-system-discipline による。

- `focus: any` で `replaceInput` を本来の送り先にも代替にも置けない。`Scope.any` は `Guarded<Sink>` しか持たない。
- `transform` の無いルールに `onFail.transform` は持てない。`Guarded<ShellCommand>?` が丸ごと無い。
- 代替の代替は持てない。`Guarded.onFail` は `Value` で、`Guarded` ではない。一発火あたりのシェルが高々 4 本になり、所要時間に上限が付く。
- 消去の代替はどのルールでも持てない。`Rule` に場所が無い。
- 作用と結果の取り違えはコンパイルが通らない。`Next.shell` は `AfterShell` を運び、`resume(AfterShell, ShellOutcome)` しか受けない。

型に乗せなかったもの。`onFail.output` を失敗しない送り先（`none`, `notify`）に付けることは型で消さず、`loadConfig` の検査一つにした。`Sink` を「失敗しうる」と「しない」に割ると、本来の送り先の型が二つに増えて得るものが無い。

**改訂 3 の `Scope` 不採用を覆す。** 改訂 3 は「列挙の入れ子までは持ち込まず `loadConfig` の検査一つにする」とした。当時、欄の有無で分岐するのは送り先の適用一か所だった。この形では、本来の送り先の適用、代替の送り先の適用、`gone` のときに書き戻しへ落ちてよいかの判定の三か所が欄の有無で分岐する。平らな型だと三か所すべてに「`replaceInput` なのに欄が無い」という到達しない分岐が要る。入れ子にすれば三つとも消える。

**Engine は解釈器、方針は reducer。** boundary-discipline による。`Fire.swift` は I/O を持たないので、失敗の表（段 × 試行 × 結果）は偽 Desktop もプロセスも無しに表駆動のテストで全部回せる。`Engine.drive` は作用を実行して結果を返すだけのループで、分岐を持たない。消去の手順（改訂 3 の手順 5）は `performErase` として Desktop の原始操作の上に一度だけ書く。`MacDesktop` と `FakeDesktop` がそれぞれ実装すると二つの手順がずれ、偽の検証が本物を保証しなくなるからだ。

**期限はエンジンが持つ。** `shellTimeout` は設定の最上位に一つだけ置く。ルールごとの期限は、`claude -p` と `curl` で違う値が要ると分かったときに足す。値を設定に出す理由は二つ。利用者の `claude -p` の待ち時間に合わせたいこと。`verify.sh` は各送りを `cap 20` で包むので、固定の 30 秒では期限の項目を一つも検証できないこと。止めるのはプロセスグループで、`Process.terminate()` は `sh` しか止めず `claude` が残る。

**出力行は確かめた後に出す。** `apply replaceInput` は読み戻しが一致したときだけ出す。そうしないと `lacks 'apply replaceInput'` の判定が意味を失う。失敗は `apply-failed replaceInput <reason>` の別の行にする。`Line` 一つの列挙が行の書式の唯一の出どころで、`Failure.token` が出力行と `KEYPIPE_FAILURE` の両方に同じ文字列を渡す。

**インターフェースの深さ。** 利用者に増える面は `onFail` のキー二つと `shellTimeout` 一つで、値の書き方は既に知っているものだけ。その裏に、失敗の分類、期限とプロセスグループ、一度きりの差し替え、書き込みの読み戻し、ハンドルの寿命の扱いを隠す。`Engine` の公開面は `init` と `key` のまま。`Desktop` は改訂 3 の 5 メソッドから 5 メソッドで、消去の手順を外に出した分だけ浅くなり、手順そのものは共有の一か所に深く入った。

### 次の代替をどこに足すか（型の継ぎ目か、シェルか）

**シェルが開いた継ぎ目、型は閉じた語彙。** 貢献者が次の代替を足す手順。

1. `{ "shell": ... }` を `onFail.output` か `onFail.transform` に書けば表せるか。tmux のセッションを作る、`pbcopy`、webhook、ファイルに追記、`say`、理由ごとの分岐（`KEYPIPE_FAILURE`）。ほとんどはここで終わる。**設定の編集だけで、Swift は触らない。**
2. シェルに無い能力が要るか（AX でしか書けない、キーを打つ必要がある）。それは代替の種類ではなく**送り先の種類**なので、`FieldSink` か `Sink` に case を一つ足す。`loadConfig` の文字列一つ、`Fire.swift` の網羅的な `switch` がコンパイルエラーで示す分岐、`Line` の書式、能力が要るなら `Desktop` の原始操作一つ。足した送り先は本来の送り先としても代替としても使える。ルール選択は触らない。
3. 新しい**失敗の種類**（たとえば「出力が長すぎる」）は、`Failure` に case を一つと、`resume` の分類一行。

最初に 2 へ来る候補は「全選択して貼り付け」（改訂 3 のリスク節の Electron 向け）。`FieldSink.paste`、`Desktop.paste(Field, String) -> Bool`、`apply paste`。Electron が `AXValue` の書き込みを本当に無視するか測ってから足す。それまでは (c) の `pbcopy` で手で貼る。

「プラグイン実行系を作らない」との関係。シェルは既にプロセス境界の外にあるプラグインの口で、任意の言語で書け、keypipe の再ビルドが要らない。型の語彙を開いた拡張点（名前で引く登録表、動的読み込み）にすると、シェルと同じことを二通り目で表す口になり、制約にも反する。だから語彙は閉じたまま、コンパイラが網羅を強制する列挙にした。制約を変える理由は見つからなかった。

### Synthesis decision

arena が記入する。

### Tradeoffs accepted

- 非ゼロ終了の代替は、`transform` や `output.shell` の中の `a || b` でも、`onFail` でも書ける重なりを受け入れる。その代わりに、期限切れと空の出力と書き込み無視という、シェルが見られない失敗を同じ一か所で扱える。README は「別の行き先へ逃がすなら `onFail`、一つの行き先の中の言い換えなら `||`」と案内する。`onFail` だけが期限切れを拾うことは (b) に書いた。
- 空の出力を常に失敗とみなす。代わりに `replaceInput` が利用者の文を空で消す経路が無くなる。空を正当な結果として送り先へ渡す書き方は無くなる（代替も空なら通知で終わる）。空を送りたい実例はまだ無い。
- 消去の失敗は固定の続行。代わりに、トリガーが欄に見えたまま残ることがある（壊さない、見える）。
- `shellTimeout` は全シェルで一つ。代わりに設定のキーが一つで済む。一発火の上限は `4 × shellTimeout` で、既定 30 秒なら最悪 2 分、その間は次の発火が待つ。
- `output.shell` の失敗の既定は今の「記録だけ」を守る。代わりに、`onFail` を書かない利用者は tmux の宛先違いに気づきにくい。
- `Scope` の入れ子を入れ、改訂 3 の判断を覆す。代わりに欄の有無の到達しない分岐が三か所消える。
- reducer と解釈器でファイルが一つ増える（`Fire.swift`）。代わりに失敗の方針がプロセスも Desktop も無しで表駆動のテストになる。

### Alternatives considered

- **代替を種類名の表で持つ**（`"onFail": {"transform": {"kind": "retry", "times": 2}}` と、Swift 側の `FallbackKind` 登録表）。プラグインらしく見えるが、表の各種類はシェルで書けることの二通り目で、種類が増えるほど利用者が覚える語彙も増える。面が広く隠すものが少ない。不採用。
- **代替を独立の段列にする**（`"steps": [...]` と失敗時の分岐先）。改訂 2 が退けた形の再来で、シェルのパイプと二通りになる。不採用。
- **代替をシェルだけに任せる**（`onFail` を作らず `||` と `trap` で書かせる）。追加の Swift は最小だが、期限切れ（エンジンが殺す）と書き込み無視（AX の後でしか分からない）を表せない。(c) が書けない。不採用。
- **Engine を命令的なまま、失敗ごとに `if` を足す**（改訂 3 の `Engine.key` に分岐を足す）。ファイルは一つ減るが、段 × 試行 × 結果の組み合わせがテストに偽 Desktop とプロセスを要求し、`Engine.key` の if の連鎖が失敗の種類ごとに伸びる。model-the-domain の「新機能が if の連鎖を一つ伸ばす」兆候そのもの。不採用。
- **継続をクロージャで持つ CPS**（`case shell(ShellRequest, (ShellOutcome) -> Step)`）。取り違えは同じく消えるが、`Step` が `Equatable` でなくなり表駆動のテストが比較できない。不採用。

### Open questions and risks

- `shellTimeout` の既定は 30 秒でよいか。長文の `claude -p` が常に 30 秒を超えるなら、ルールごとの期限が要るか。
- `onFail` を書かない `output.shell` の失敗を、記録だけから通知へ変えるか。変えると今の振る舞いが変わる。
- `replaceInput` の失敗の既定通知に結果の全文を載せてよいか（通知センターに機密が残る）。
- `fieldGoneAfter` 以外に、偽 Desktop で「消去の時点で既にハンドルが死んでいる」場合を再現する必要があるか。
- Electron の欄で `setText` の後の読み戻しが一致しない（`ignored`）とき、遅れて書き込みが反映されることはあるか。あると代替の `pbcopy` と二重になるが、欄の文は壊れない。
- `posix_spawn` の `POSIX_SPAWN_SETPGROUP` で切り離したグループが、端末の SIGINT を受けなくなる副作用は daemon で問題にならないか（推測では問題にならない）。

### Next implementation step

`Tests/keypipeTests/FireTests.swift` に、段 × 試行 × 結果の表（下の R9 と同じ行）を書き、`Fire.swift` の `start` / `resume` を緑にする。

## 6. 先に構造を直す計画

方針。改訂 3 の形に偽 Desktop の上で到達するまでを「構造の改善」とし、利用者に見える新しい能力（実機のキー取得、AX、代替）はその後に置く。各段は単独で入り、終わりに `swift test` か `verify.sh --no-live` の特定の項目が緑になる。sequence-verifiable-units による。改訂 3 の固定の方針（変換失敗で通知）は reducer の最初の版でそのまま表し、代替は reducer が緑になってから足す。期限は代替より先、実機より先に入れる。実機で最初に `claude -p` が固まった時点で daemon が止まるのを防ぐためだ。

### 構造の改善（新しい能力なし）

**1. 消す。** `log` アクションと `logPath` を消す。`Sources/keypipe/Actions.swift` の `log` 分岐、`Config.swift` の `logPath`、`main.swift` の `logPath` 受け渡し、`Tests/keypipeTests/ActionsTests.swift` の log の項目、`config.example.json` の log ルール。確認は `swift test`。subtract-before-you-add による（足す前に消す）。

**2. 照合器はトリガーだけを返す。** `TriggerMatcher(triggers: [String])`、`feed -> String?`。`TriggerRule` と `contextMatches` の呼び出しを消す。規則の引き当ては `main.swift` の `feedAndRun` で設定順の最初の規則を引く（今の挙動と同じ）。`Sources/keypipe/Trigger.swift`、`main.swift`、`Tests/keypipeTests/TriggerTests.swift`（`testFirstRuleWins` は照合器の項目でなくなるので `feedAndRun` 側へ移す）、`TriggerExhaustiveTests.swift`、`.claude/skills/verify-keypipe-trigger/`。確認は `swift test` と verify-keypipe-trigger。`--smoke-feed '@@@'` の出力行が変わらないこと。

**3. シェルを一本にし、期限を付ける。** `Sources/keypipe/Shell.swift` の `runShell(ShellRequest) -> ShellOutcome`（stdin、`$1`、`KEYPIPE_INPUT`、プロセスグループ、期限）。`Actions.swift` を削除し、旧 `shell` アクションは `runShell` を通す。期限はこの段では定数 30 秒で、テストは `ShellRequest.timeout` に短い値を渡す。`Tests/keypipeTests/ShellTests.swift`（`ActionsTests.swift` を置き換え）。確認は `swift test` で、`sh -c 'sleep 30 & wait'` が 2 秒以内に `.timedOut` を返し、子の `sleep` も残らないこと（`kill -0` で確認）。`$()` とバッククォートを含む入力が `$1` にバイト単位で届くこと。

**4. 新しい設定の境界。** `Config.swift` を改訂 3 の形に `Scope` と `Guarded` を入れて書き直す。この段では `onFail` と `shellTimeout` は `unknown key` で拒否する。`Context.swift` は `MatchContext` を消し `Focus`, `Field`, `Snapshot`, `select`。`Action` が消えるので `main.swift` の `feedAndRun` も同じ段で直す。最小の配線は「`select` に `Snapshot(app: nil, focus: .nothing, field: nil)` を渡し、`keypipe matched <trigger> rule <n>` を出し、`transform` と `output.shell` を空の入力で `runShell` に通す」。この仮の配線は 6 で `Engine` に置き換えて消す。`Tests/keypipeTests/ConfigTests.swift`、`ContextTests.swift`。確認は `swift build` が通ることと、 `verify.sh --no-live` の R2a-f（`--context` を使わない項目）と `swift test`。

**5. 純粋な reducer と出力行。** `Sources/keypipe/Fire.swift` に改訂 3 の固定の方針だけを持つ `start` / `resume` と `Line`。`Failure` は `exit` と `timeout` だけ。`Tests/keypipeTests/FireTests.swift` に、成功、変換失敗で通知、変換期限で通知、消去の三つの結果の行。確認は `swift test`。

**6. 偽 Desktop と解釈器。** `Sources/keypipe/Desktop.swift`（プロトコルと `FakeDesktop`、改訂 3 の `--context` キー）、`Sources/keypipe/Engine.swift`（`drive`, `performErase`, `performWrite`）、`main.swift`（`feedAndRun` を消し `Engine` を配線、`--context`、`keypipe field`）。確認は `verify.sh --no-live` の R2-R8 全項目。

**ここで構造の改善は終わる。** 偽 Desktop の上で改訂 3 の契約がすべて緑。以降が機能。

### 機能

**7. 実機。** `Sources/keypipe/MacKeyTap.swift`（listen-only の CGEventTap、自分の事象を `eventSourceUserData` で除く、配送後にメインキューで `Engine.key`）、`Sources/keypipe/MacDesktop.swift`（原始操作 5 つ、`--probe`）。確認は Mac で `verify.sh` の M0-M4。

**8. 代替。** `Config.swift` で `onFail` と `shellTimeout` を受け、拒否理由 4 つ（`onFail.transform requires transform`、`onFail.output requires an output that can fail`、`unknown key erase`、`shellTimeout must be positive`）。`Fire.swift` に `Attempt.fallback`、`Failure.empty/ignored/gone`、`KEYPIPE_FAILURE`、行 `fallback ...` / `transform empty` / `apply-failed` / `erase-failed`。`Desktop.swift` の `FakeDesktop` に `ignoresWrite` と `fieldGoneAfter`。`FireTests.swift` に代替の表。`.claude/skills/verify-keypipe-rules/SKILL.md` の行の表と理由の一覧、`verify.sh` に次の項目。`config.example.json`、`README.md`、`README.ja.md`、`docs/design/context-rules.md`。確認は `swift test` と `verify.sh --no-live` の R9。

| ID | 何を | 合否 |
| --- | --- | --- |
| R9a | `shellTimeout: 1`、`transform: "sleep 5"`、`onFail.transform: "tr a-z A-Z"` | `transform timeout 1`、`fallback transform exit 0`、欄 `"HELLO"`、`cap 20` 内で終わる |
| R9b | `transform: "exit 3"`、`onFail.transform: "exit 4"` | `fallback transform exit 4`、`apply notify`、`apply replaceInput` 無し、欄 `"hello"` |
| R9c | `transform: "true"`（空の出力）、`onFail` 無し | `transform empty`、`apply notify`、欄 `"hello"`（空にならない） |
| R9d | `output.shell: "exit 1"`、`onFail.output.shell` が副作用ファイルへ `$1` と `$KEYPIPE_FAILURE` を書く | `output-shell exit 1`、`fallback output-shell exit 0`、ファイルが `hello` と `exit 1` |
| R9e | `--context` に `"ignoresWrite": true`、`replaceInput`、`onFail.output.shell` が副作用ファイル | `apply-failed replaceInput ignored`、`apply replaceInput` 無し、ファイルが結果 |
| R9f | `"fieldGoneAfter": "erase"`、`replaceInput`、`onFail` 無し | `apply-failed replaceInput gone`、`apply notify "HELLO"` |
| R9g | 代替も期限切れ（`onFail.transform: "sleep 5"`） | `fallback transform timeout 1`、`apply notify`、シェルは 2 本で止まる |
| R9h-k | 拒否 4 種（上の表） | exit 1 と理由の文字列 |
| R9l | 受け皿ルール（同じトリガー、`when` なし）が先行ルール不成立で `matched @@@ rule 1` | `nomatch` 無し |

**9.（保留）全選択して貼り付け。** Electron で `AXValue` の書き込み無視を測ってから。`FieldSink.paste`、`Desktop.paste`、`MacDesktop`、`FakeDesktop` の `ignoresWrite` との組み合わせで R9e の変種。

順序の理由。1 で消してから 2-3 で形を変えるので、各段の差分は小さい。4 の R2a-f は `--context` が要らないので最初に緑になる検証項目。5 を 6 より先にするのは、reducer を偽 Desktop 抜きで先に確かめ、6 の失敗を解釈器の不具合に絞るため。7 を 8 より先にするのは、M1-M3 が MVP の合格条件で、8 の `ignored` と `gone` を実機の `performWrite` で確かめられるのが 7 の後だから。期限（3）だけは 7 より前に入る。
