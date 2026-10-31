# 候補 1: 最小の形（コンテキスト 3 状態 + 外部処理はすべてシェル）

改訂 2 の骨格（`trigger` + `when` + `transform` + `output`、`Desktop` 境界、固定の発火手順）はそのまま使う。変えるのは 4 点だけ。

1. スナップショットのフォーカスを 3 状態の列挙にする（`nothing` / `text` / `composing`）。`composing` は `when` の軸にせず、エンジンの門にする。
2. `focus` の意味を「欄を使うか」に固定する。`textField` は欄を読む。`any` は欄を読まず、書き戻しもしない。
3. アプリ固有の癖はレジストリを作らない。Backspace 無視（事実 5）は読み戻しで自己修正する。ターミナル（事実 4）は設定の `when.app` で書き分ける。
4. 組み込みの送り先は `replaceInput`、`notify`、`none` だけにする。`clipboard` は `pbcopy`、webhook は `curl`。全部 `output.shell` で書く。

## 1. 使い方（利用者が書く設定）

`~/.config/keypipe/config.json`。三つの実例を一つの設定に並べる。

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
      "trigger": ";;t",
      "when": { "app": ["com.googlecode.iterm2"], "focus": "any" },
      "transform": "tmux capture-pane -p -J | awk 'NF{l=$0} END{print l}' | sed 's/^.*❯ //'",
      "output": { "shell": "tmux send-keys -t work:agent -l \"$1\" && tmux send-keys -t work:agent Enter" }
    },
    {
      "trigger": ";;w",
      "when": { "app": ["com.googlecode.iterm2", "com.apple.Terminal"], "focus": "any" },
      "output": "none"
    },
    {
      "trigger": ";;w",
      "when": { "focus": "textField" },
      "output": { "shell": "curl -sS -m 5 --data-urlencode text@- --data-urlencode \"app=$KEYPIPE_APP\" \"$(cat ~/.config/keypipe/hook-url)\"" }
    }
  ]
}
```

各例の読み方。

- **TextEdit で訳して置換。** TextEdit の本文で `こんにちは@@@` と打つと、`@@@` を消し、`こんにちは` を `claude -p` に stdin で渡し、出力で本文を置き換える。TextEdit は合成 Backspace を無視する（事実 5）が、エンジンが読み戻して `@@@` が残っていれば取り除いて書き戻すので、利用者は気にしなくてよい。`app` を TextEdit に絞るのは、絞らないと iTerm2 でも発火して画面全体（約 3,800 文字）が入力になるため（事実 4）。
- **iTerm2 から tmux へ送る。** iTerm2 の AX 上の「欄」は画面全体で、プロンプトの行ではない（事実 4）。だから `focus: any` にして AX の欄は読まない。入力はターミナル自身から取る。`transform` が `tmux capture-pane` で今のペインの最後の非空行を取り、プロンプト記号より後ろを残す。`output.shell` がそれを `work:agent` ペインへ送る。打った `;;t` は Backspace で消す（pty へ届く。未検証）。
- **任意のアプリから webhook。** `;;w` で欄の文字を `curl` の stdin に渡す。URL は daemon の環境に無い前提でファイルから読む（launchd 起動の daemon はログインシェルの環境変数を継がない）。ターミナルで画面全体を送らないよう、同じトリガーのターミナル用ルールを先に置いて食わせる（設定順で最初に満たしたルールが勝つ）。

規則の要約。

- `when.app` は bundle id のどれか。省略は全アプリ。調べ方は `keypipe --probe`。
- `when.focus`
  - `"textField"` 欄を使うルール。フォーカスが AX のテキスト欄（`AXTextField` / `AXTextArea`）のときだけ発火する。トリガーを消し、欄の文字が入力になる。
  - `"any"`（既定） 欄を使わないルール。テキスト欄でも欄以外でも発火する。入力は空文字。テキスト欄なら Backspace でトリガーを消すが、読み戻しも書き戻しもしない。欄以外なら何も送らない。
- IME の変換中（マーク付きテキストがある）は、どのルールも発火しない。`keypipe composing <trigger>` を出して終わる。
- `transform` と `output.shell` は入力を stdin、`$1`、`KEYPIPE_INPUT` で受け、前面アプリを `KEYPIPE_APP` で受ける。`$1` で受ければクォートを自分で組まなくてよい（R8 の前提）。
- 組み込みの送り先は `"replaceInput"`、`"notify"`、`"none"` だけ。それ以外は `{ "shell": "..." }`。クリップボードは `{ "shell": "pbcopy" }`、CotEditor は `{ "shell": "printf %s \"$1\" | cot" }`。

## 2. 型の下書き

使い方から導いた。本体は `notImplemented()`。

```swift
// Config.swift — the only place JSON is parsed and validated.
public enum FocusFilter: String { case textField, any }

/// Sinks the engine itself needs: AX write into the focused app, and the
/// notification it also uses for a failed transform (R5c). Everything else is `.shell`.
public enum BuiltinSink: String { case none, replaceInput, notify }

public enum Output: Equatable {
    case builtin(BuiltinSink)
    case shell(String)  // non-empty, checked in parseConfig
}

public struct When: Equatable {
    public var app: Set<String>?  // nil = any app
    public var focus: FocusFilter  // default .any
}

public struct Rule: Equatable {
    public var trigger: String  // 1...triggerMaxBuffer chars
    public var when: When
    public var transform: String?  // nil = identity; never empty
    public var output: Output  // default .builtin(.none)
}

public struct KeypipeConfig: Equatable { public var rules: [Rule] }

/// Rejects unknown keys at every level and throws
/// `invalid config: <reason>` with the reasons the verifier matches literally.
public func parseConfig(_ data: Data) throws -> KeypipeConfig { notImplemented() }
public func loadConfig(path: String) throws -> KeypipeConfig { notImplemented() }
```

```swift
// Context.swift — what the desktop looked like when the trigger completed.
public enum Focus: Equatable {
    case nothing  // focused element exists but is not a text element (Finder desktop is an AXGroup)
    case text  // AXTextField or AXTextArea, no marked text
    case composing  // text element whose AXTextInputMarkedRange.length > 0
}

public struct Snapshot: Equatable {
    public var app: String?
    public var focus: Focus
}

/// Pure. `.composing` never reaches here; the engine gates it first.
public func matches(_ when: When, _ s: Snapshot) -> Bool { notImplemented() }

/// First rule in config order with this trigger whose `when` holds. Returns its index.
public func select(_ rules: [Rule], trigger: String, _ s: Snapshot) -> Int? { notImplemented() }
```

```swift
// Trigger.swift
public struct TriggerMatcher {
    /// Distinct triggers, longest first. Rule selection is not its job.
    public init(triggers: [String], maxBuffer: Int = triggerMaxBuffer)
    public mutating func feed(_ c: Character) -> String?  // the matched trigger
    public mutating func reset()
}
```

```swift
// Desktop.swift — the only port to AX and CGEvent.
public protocol Desktop: AnyObject {
    func snapshot() -> Snapshot
    func erase(_ count: Int)  // post Backspace; may be ignored by the app
    func fieldText() -> String
    func apply(_ sink: BuiltinSink, text: String)  // .replaceInput writes AXValue
}
```

```swift
// Engine.swift — the fire sequence, the only place it exists.
public typealias Shell = (_ command: String, _ input: String, _ env: [String: String]) -> (status: Int32, stdout: String)

public struct Engine {
    public init(config: KeypipeConfig, desktop: Desktop, shell: @escaping Shell)
    public mutating func key(_ c: Character) { notImplemented() }

    // TODO fire(trigger):
    //   s = desktop.snapshot()
    //   if s.focus == .composing { emit("composing \(trigger)"); return }
    //   guard let i = select(rules, trigger, s) else { emit("nomatch \(trigger)"); return }
    //   emit("matched \(trigger) rule \(i)")
    //   input = rule.when.focus == .textField ? eraseAndRead(trigger) : eraseOnly(trigger, s)
    //   result = transform.map { run; emit("transform exit"); on failure notify and return } ?? input
    //   output: .builtin -> desktop.apply + emit("apply ..."), .shell -> run + emit("output-shell exit")
    //   matcher.reset() in every branch

    /// Read, Backspace, read again. If the two reads are identical the app
    /// ignored the Backspace (TextEdit), so strip the trailing trigger and
    /// write it back. Comparing both reads, not just the suffix, keeps a
    /// field that legitimately ends with the trigger text from losing it twice.
    /// Detects the quirk by observation, not by bundle id.
    private func eraseAndRead(_ trigger: String) -> String { notImplemented() }

    /// Backspace only when focus is .text; never reads or writes the field.
    private func eraseOnly(_ trigger: String, _ s: Snapshot) { notImplemented() }
}

/// `/bin/sh -c <cmd> keypipe <input>` with input on stdin, `$1`, KEYPIPE_INPUT.
public func runShell(_ command: String, input: String, env: [String: String]) -> (status: Int32, stdout: String) { notImplemented() }
```

```swift
// FakeDesktop.swift — driven by --context JSON.
// {"app":..,"focusIsTextField":bool,"composing":bool?,"ignoresBackspace":bool?,"fieldText":..}
// composing && !focusIsTextField is rejected at parse time.
public final class FakeDesktop: Desktop {
    public init(contextJSON: Data) throws
    public func type(_ c: Character)  // typed keys append to fieldText
    public var field: String { get }  // printed as `keypipe field <json>`
}

// MacDesktop.swift — #if os(macOS). Focus is derived from AXRole and
// AXTextInputMarkedRange, never from a nil focused element.
public final class MacDesktop: Desktop { }

// MacKeyTap.swift — listen-only CGEventTap. Drops events whose
// eventSourceUserData is keypipe's own mark. Calls engine.key on the
// main queue after the event is delivered, so the field already holds
// the last trigger character when the engine reads it.
public func runKeyTap(_ onKey: @escaping (Character) -> Void) -> Never { notImplemented() }
```

## 3. モジュール一覧

`Sources/keypipe/` 配下。発火を追うのに開くファイルは `Engine.swift` と `Context.swift` の二つで足りる。

| ファイル | 持つもの |
| --- | --- |
| `Config.swift` | 設定の型、`parseConfig`、`loadConfig`、拒否理由の文言 |
| `Context.swift` | `Focus`、`Snapshot`、`matches`、`select`（純粋関数） |
| `Trigger.swift` | `TriggerMatcher`（トリガー文字列だけを返す） |
| `Engine.swift` | 発火手順、消去と読み戻し、`runShell`、出力行 |
| `Desktop.swift` | `Desktop` プロトコル |
| `FakeDesktop.swift` | `--context` の偽物 |
| `MacDesktop.swift` | AX と CGEvent の実装。フォーカス 3 状態の導出 |
| `MacKeyTap.swift` | CGEventTap、自分の post の除外、メインキューへの受け渡し |
| `main.swift` | 引数、`--smoke-feed`、`--feed-stdin`、`--context`、`--probe`、daemon |

`Actions.swift` は消す。

## 4. 根拠

### Problem

トリガーを打った瞬間の状況でルールを選び、欄の文字を変換して送り先へ渡す。形を難しくしているのは、実機で測った三つの事実。iTerm2 のプロンプトは AX 上 TextEdit と同じ `AXTextArea` で、値は画面全体（事実 4）。合成 Backspace は TextEdit だけ無視される（事実 5）。IME の変換中はタップがローマ字の打鍵を見るのに、欄はかなを持つ（事実 7）。守る制約は、トリガー 64 文字上限と最長一致、短いトリガーへ落ちないこと、設定が唯一の宣言場所であること、`Desktop` が AX と CGEvent の唯一の境界であること、拒否理由の文言、出力行の契約。

### Usage (caller's view)

1 節の通り。利用者が書くのは JSON 一つ。ルール作者が観測して書けるのは「前面アプリ」と「このルールは欄を使うか」の二つだけで、それ以外の状況はエンジンが吸収する。

### Shape

**スナップショットの型と、区別する状態。** `Snapshot { app: String?, focus: Focus }`、`Focus` は `nothing` / `text` / `composing`。

- `text` と `nothing` を分ける根拠は事実 6。Finder の机上でも `AXFocusedUIElement` は nil でなく `AXGroup` なので、nil 判定では「何もフォーカスしていない」を取れない。役割（`AXTextField` / `AXTextArea`）で導く。ルール作者がこの区別を使うのは「欄のある所でだけ置換する」（`focus: textField`）と「どこでも動く」（`focus: any`）の二通りで、`nothing` を名指しするルールは誰も書かない。だから `when` の値は増やさない。
- `composing` の根拠は事実 7。TextEdit で `AXTextInputMarkedRange` が取れ、ATOK の変換中は長さが正。この状態でトリガー文字数ぶん Backspace を送ると、変換中のかなを消す（変換中の文字に Backspace が効くことは測定済み）。ルール作者は「変換中にだけ動くルール」を書かないので、`when` の軸ではなくエンジンの門にした。
- 列挙一つにしたのは、「テキスト欄でないのに変換中」という状態を型で表せなくするため（type-system-discipline による）。`--context` の JSON は互換のため `focusIsTextField` を残し、`composing` を足して境界で列挙へ変換する。

**変換中に打ったトリガー。** 発火しない（無視）。`keypipe composing <trigger>` を出して matcher を空にする。遅延して確定後に発火する案は捨てた。タップが見た `@@@` と欄の `＠` は数も文字も合わない（事実 7 の `hello@@@` → `へっぉ＠`）ので、確定を待っても消す文字数を決められない。利用者から見ると、日本語入力モードではトリガーが効かず、英数に切り替えて打てば効く。新しい出力行にしたのは、M3 が数える `nomatch` を汚さないため。

**`focus` の意味を「欄を使うか」に固定。** 改訂 2 では入力が「その瞬間テキスト欄だったか」で変わり、`focus: any` のルールでも Backspace を送っていた。この候補では入力の出どころをルールが決める。`textField` は消して読む。`any` は読まず、入力は空文字。これでルール作者は設定だけを見て `$1` に何が入るかを言える。副作用が二つ消える。

- `any` のルールが iTerm2 で画面全体を読み、読み戻しの書き戻しで画面全体の `AXValue` を書く経路（事実 4 と 5 の組み合わせ）。
- フォーカスが `nothing` のときの Backspace。欄以外での Backspace はアプリによっては削除コマンドになる（Mail の選択メッセージ削除など。推測、未測定）。トリガー文字は欄に入っていないので、消すものも無い。`keypipe erase 0` を出す。

**アプリ固有の癖の置き場所。** レジストリは作らない。

- 事実 5（TextEdit の Backspace 無視）は `Engine.eraseAndRead` の読み戻しで扱う。消す前に一度読み、Backspace を送り、もう一度読む。二回の読みが同じなら Backspace は無視されたので、末尾のトリガーを取り除いて `apply(.replaceInput)` で書き戻し、`keypipe erase-rewrite` を出す。末尾だけで判定しないのは、欄がもともとトリガーと同じ文字で終わっていたとき（貼り付けなど）に二重に消さないため。bundle id を見ずに結果を見るので、TextEdit 以外で同じ癖が出ても直る。偽 Desktop の `"ignoresBackspace": true` でこの経路を試せる。
- 事実 4（ターミナルが `AXTextArea`）はコードで判別しない。判別の候補 `AXRoleDescription` は未検証なので、それに乗る型を作らない。ルール作者が `when.app` で書き分ける（1 節の `;;t` と `;;w`）。
- 次の癖を足す規則。観測で直せる癖（読み戻して違えば直す）は `Engine` の消去手順に足す。AX の知識が要る癖（属性の読み方、`Focus` の導き方）は `MacDesktop` に足す。どちらも `matches` と `select` には触らない。ルール選択に効く癖は設定の `when.app` で書く。

**webhook。** シェルの書き方で、組み込みにしない。事実 10 の通り不確かな点が無い。組み込みにすると URL、ヘッダ、認証、本文の形、期限、再試行を設定のキーとして持ち直すことになり、`curl` の面を複製する（「同じことを二通りでできる」）。入力は stdin か `$1` で渡るのでクォート事故は起きない（R8 の検証範囲）。秘密は daemon の環境に無いので、ファイルか `security find-generic-password -w` で読む。遅い先へ送るなら利用者が末尾に `&` を付けて待たない選択をする。

**組み込みの送り先を減らす。** `clipboard` は `pbcopy` でシェルから書けるので、残すと同じことに二つの書き方ができる。`insert` はどの実例も使わない。残すのは、フォーカス中のアプリの中でしかできない `replaceInput`、エンジン自身が変換の失敗時（R5c）に使う `notify`、既定の `none`。`notify` もシェルの `osascript` で書けるが、エンジンが持たざるを得ない部品なので、送り先として見せても面は増えず、利用者は `osascript` のクォートを書かずに済む。

**実行の順序とタイミング。** 発火は `MacKeyTap` がイベント配送の後にメインキューで呼ぶ。listen-only のタップはアプリより先にキーを見るので、その場で欄を読むと最後のトリガー文字がまだ入っていない（推測、未測定）。

**妥当性と実現性の判定（測定事実に照らして）。**

| 軸 | 妥当か | 実現できるか | 根拠 |
| --- | --- | --- | --- |
| 前面アプリ | 妥当 | できる | `NSWorkspace.frontmostApplication.bundleIdentifier`、プローブで取得済み |
| テキスト欄にフォーカス | 妥当。ただし「編集欄」としては広すぎる | できる（役割で導く） | 事実 3、事実 4 |
| 何もフォーカスしていない | 妥当。状態として導くもので、`when` の値にはしない | できる（nil ではなく役割で） | 事実 6 |
| IME 変換中 | 妥当。エンジンの門として | TextEdit ではできる。他のアプリは未測定 | 事実 7 |
| アプリ固有の扱い | 必要。ただし入力側だけ | Backspace 無視は読み戻しで汎用に直せる。ターミナルは設定で | 事実 4、事実 5 |
| シェル | 妥当 | できる | 現行の `runShell`、R5、R6、R8 |
| webhook | シェルの書き方で足りる | できる | 事実 10 |
| アプリ固有の外部処理 | ルールの関心ではない。`cot`、`tmux`、`osascript` をシェルで呼ぶ | できる | 改訂 2 の CotEditor 例 |

改訂 2 の誤りは三つ。`focus: any` で欄を読み Backspace を送ること、変換中を区別しないこと、シェルで書ける送り先を組み込みに持つこと。

**インターフェースの深さ。** 利用者の面は JSON のキー 5 個（`trigger`、`when.app`、`when.focus`、`transform`、`output`）と組み込み 3 個。その裏に、フォーカスの導出、変換中の門、Backspace 無視の自己修正、自分の post の除外、配送後の呼び出しを隠す。内部の面は `Desktop` の 4 メソッドで、改訂 2 から増やしていない。

### Synthesis decision

arena が記入する。

### Tradeoffs accepted

- 日本語入力モードではトリガーが効かないことを受け入れる。代わりに、変換中のかなを誤って消すことが無くなる。
- ターミナル除けを設定の先行ルールで書くことを受け入れる（`;;w` のターミナル用 `none` ルール）。代わりに、未検証の判別子に乗る型を作らない。
- `focus: any` のルールは欄の文字を受け取れないことを受け入れる。代わりに、入力の出どころが設定だけで決まり、画面全体の書き戻しと欄以外での Backspace が無くなる。
- クリップボードを `pbcopy` で書くことを受け入れる。代わりに、組み込みが三つに減り、二通りの書き方が無くなる。`notify` だけはシェルと重なるが、エンジンが内部で要るので残す。
- 改訂 2 のレビューで決めた既定「`focus: any` でも消す」を、「テキスト欄のときだけ消す」に変える。

### Alternatives considered

- **アプリ別の癖表（bundle id → 消去方法、入力の取り方）。** 癖をコードに名指しで溜める。表の行を足すたびに `MacDesktop` とテストが増え、表に無いアプリの同じ癖は直らない。読み戻しは同じ事実 5 を表なしで、未知のアプリにも効く形で扱う。測定済みの癖でアプリ名が要るものは一つも無いので不採用。
- **`when.focus` に `composing` / `nothing` / `terminal` を足す。** ルール作者に AX の内部状態を学ばせる。`composing` で動かしたいルールも、`nothing` を名指ししたいルールも、実例に無い。`terminal` は判別子が未検証。面が広がるだけで隠すものが無いので不採用。
- **webhook の組み込み（`{ "webhook": { "url", "headers", "body" } }`）。** `curl` の機能を設定のキーとして写し直す浅い面。シェルと二通りの書き方になる。不採用。
- **入力の出どころを別キー（`"input": "field" | "none"`）にする。** 意味は今回の `focus` の固定と同じで、キーが一つ増え、`focus: textField` と `input: none` の組のような無意味な組み合わせを許す。`focus` に意味を寄せた方が面が小さいので不採用。

### Open questions and risks

- iTerm2 の画面全体の `AXValue` へ書き込むと何が起きるか。`app` を絞らない `focus: textField` + `replaceInput` のルールを書くと、ターミナルで画面全体が入力になり、書き戻しが走る。既定の設定例で `app` を絞るだけで十分か、それとも次の測定（`AXRoleDescription` を 2 種以上のターミナルとブラウザの欄で取る）を実装前にやるか。
- TextEdit 以外のアプリが `AXTextInputMarkedRange` を出すか。出さないアプリでは変換中を `text` と見て、変換中のかなを消す。対象アプリを決めて測るか。
- 配送後に呼ぶ遅れは、メインキューへの非同期で足りるか、短い待ちが要るか。M1 で測れる。
- Backspace を送った直後の読み戻しが、アプリの処理より先に走らないか。先に走ると二回の読みが同じになって書き戻しが走り、その後で遅れて届いた Backspace がトリガーより前の文字を消す。読み戻しの前の待ちの長さは未検証。
- espanso の `@@` と取り合う件（事実 8）は範囲外のまま。トリガーを espanso と接頭辞が重ならないものにする運用で足りるか。

### Next implementation step

`Context.swift` に `Focus` 3 状態と `matches` / `select` を書き、偽 Desktop の `composing` と `ignoresBackspace` を足して、R3 と R4 に「変換中は不発火」「Backspace 無視で書き戻し」の 2 項目を加えて通す。

### 改訂 2 からの最小の変更（ファイル一覧）

改訂 2 の変更範囲に、次の差分を足すだけ。

- `docs/design/context-rules.md` `Focus` 3 状態、`focus` の意味の固定、変換中の不発火、組み込みを `replaceInput` / `notify` / `none` に縮小、二回読みでの書き戻し判定、「`focus: any` でも消す」の撤回。
- `Sources/keypipe/Context.swift` `Snapshot.focusIsTextField` を `Focus` 列挙に置き換え。
- `Sources/keypipe/Config.swift` `BuiltinSink` から `insert` と `clipboard` を外す。
- `Sources/keypipe/Engine.swift` 変換中の門、`eraseAndRead` と `eraseOnly` の分岐、出力行 `composing` と `erase-rewrite`。
- `Sources/keypipe/MacDesktop.swift` 役割と `AXTextInputMarkedRange` から `Focus` を導く。
- `Sources/keypipe/FakeDesktop.swift` `--context` に `composing` と `ignoresBackspace`。
- `Sources/keypipe/MacKeyTap.swift` 配送後にメインキューで呼ぶ。
- `Sources/keypipe/main.swift` `--probe` に `composing` を足す。
- `.claude/skills/verify-keypipe-rules/SKILL.md` 出力行 `keypipe composing <trigger>` と `keypipe erase-rewrite`、`erase 0` の意味、`--context` と `--probe` の新しいキー、R3e（変換中は不発火）、R3f（`focus: any` は欄を読まない）、R4c（Backspace 無視で書き戻し）。
- `config.example.json`、`README.md`、`README.ja.md` 1 節の三例。
