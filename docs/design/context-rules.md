# keypipe 設計案: コンテキスト付きルール（改訂 3）

レビュー用の設計スケッチ。実装前。改訂 2 はレビュー回答（選択は扱わない、変換と送り先は差し替え可能）を反映した。改訂 3 は実機検証と設計 arena（候補 2 本、2026-10-31）の統合。変更点は「Synthesis decision」に列挙。処理ごとのフォールバック（`onFail`、`shellTimeout`）と、構造を先に直す実装順序は [`failure-fallback.md`](failure-fallback.md)。

## Problem

今の keypipe は「トリガー文字列 → shell か log」だけを持つ。`MatchContext` はあるが `contextMatches` は常に true で、`TriggerMatcher.feed` は `app: nil` で呼んでいる。キー取得（CGEventTap）も未配線。

やりたいことは、トリガー入力を起点に、その瞬間の状況（前面アプリ、フォーカスがテキスト欄か）でルールを選び、欄の文字を変換に通し、結果を設定した送り先へ渡すこと。変換（シェルスクリプト、`claude -p`、API 呼び出し）も送り先（欄の置換、tmux、Herdr、Grok Bot、CotEditor、任意のスクリプトの引数）も、設定だけで差し替えられるようにする。

形が自明でない理由は二つ。

- 同じトリガーを状況違いの複数ルールが共有する。今の matcher はバッファだけでルールを一つに決めてしまう。
- 打ったトリガー文字はアプリに届く。`@@@` を消さないと欄のテキストに混ざる。

守る制約。トリガー長 64 文字上限と最長一致優先は維持する。Linux の `--smoke-feed` と `--feed-stdin` は単体テスト用の経路として維持する。検証の合否は Mac で出す。

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
      "when": { "focus": "any", "app": ["com.googlecode.iterm2"] },
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
- `hotkey`（2026-11-01 追加） `trigger` の代わりに書く修飾キー付きの組み合わせ。ルールにはどちらか一つ。`"ctrl+@"`、`"alt+cmd+x"`。修飾は `ctrl`/`alt`/`cmd`（別名 `control`/`option`/`command`）で最低一つ。shift は修飾ではなく文字に畳む（`"ctrl+A"`）。文字は `UCKeyTranslate` で keycode と shift から現在の配列で求める（合成事象に埋め込まれた文字列は shift を無視し、ctrl では制御文字になるため。プローブ `probes/chord.swift` で確認）。ホットキーは消さない（`erase 0`）。`textField` なら欄の全文が入力。どのルールにも無い組み合わせは desktop に触れず黙って捨てる（Cmd+C ごとに AX を呼ばない）。組み合わせは文字列バッファを空にする。tap は listen-only で前面アプリも必ず受け取るので、アプリ側の束縛を keypipe が検知して譲ることはできない。譲りたければ `when.app` で絞る。自動で譲るには非 listen-only の tap と別設計が要り、作らない。
- `when` 省略したキーはワイルドカード。`app` は bundle id のどれか。同じトリガーの候補は設定順で最初に満たしたものが勝つ。
- `when.focus` は「このルールが欄を使うか」を表す。
  - `textField` 欄を使うルール。フォーカスが AX のテキスト欄（`AXTextField` / `AXTextArea`）のときだけ発火する。トリガーを消し、欄の文字（トリガーを消した後）が入力になる。`replaceInput` を使えるのはこの値のときだけ（設定エラー `output replaceInput requires focus textField`）。
  - `any`（既定） 欄を使わないルール。どこでも発火する。入力は空文字。フォーカスがテキスト欄ならトリガーだけ Backspace で消し、欄は読まない。テキスト欄でなければ何も送らない（`keypipe erase 0`）。
- IME の変換中（`AXTextInputMarkedRange` の長さが正）はどのルールも発火しない。`keypipe composing <trigger>` を出して終わる。日本語入力モードではトリガーは効かず、英数に切り替えて打つ。
- `transform` 省略可。シェルコマンド。入力を stdin と `$1` と `KEYPIPE_INPUT` で受け、stdout が結果になる。省略すると入力がそのまま結果になる。
- `output` 結果の行き先。二種類のどちらか。
  - 組み込み（アプリ内でしかできないか、エンジン自身が使うもの）。`"replaceInput"` / `"notify"` / `"none"`。
  - 外部（それ以外全部）。`{ "shell": "..." }`。結果を stdin と `$1` と `KEYPIPE_INPUT` で受ける。tmux、Herdr、Grok Bot、CotEditor、webhook、クリップボード、任意スクリプトの引数はすべてこちらで書く。CotEditor なら `{ "shell": "printf %s \"$1\" | cot" }`、クリップボードは `{ "shell": "pbcopy" }`、webhook は `{ "shell": "curl -sS -m 5 --data-urlencode text@- \"$(cat ~/.config/keypipe/hook-url)\"" }`。JSON 本文が要る webhook は `jq` を使う（標準の macOS には無い。これが shell 方式の上限）。
- 環境変数 `KEYPIPE_APP` に前面アプリの bundle id を入れる。

発火の手順は固定。

1. matcher がトリガー一致を報告する。tap はキーをアプリより先に見るので、呼び出しはイベント配送後にメインキューで行う。
2. その時点のスナップショット（前面アプリ、`Focus`、欄のハンドル）を取る。`Focus` が `composing` なら `keypipe composing <trigger>` を出して終わる。
3. `when` を評価し、ルールを一つ選ぶ。満たすルールが無ければ何もしない。最長一致したトリガーのルールがどれも満たさなくても、短いトリガーのルールへは落ちない。
4. トリガーを消す。`Focus` が `text` なら Backspace を送る（`any` のルールでも）。`nothing` なら送らない。
5. `focus: textField` のルールだけ欄を読む。消す前に一度読み、Backspace の後は値が「消す前の値からトリガーを除いたもの」に一致するまで期限（200 ms 程度、未検証）まで待ってから読み直す。「最初の変化」で抜けると、Backspace 3 本のうち 1 本だけ届いた時点の `hello@@` が入力になる（レビューで模擬境界により再現）。期限まで値が変わらなければ Backspace は無視された（TextEdit。実機検証済み）ので、トリガーを除いた値を `AXValue` に書き戻し、`keypipe erase-rewrite` を出す。消す前の値がトリガーで終わっていなければ待たずに読み直す。
6. `transform` を実行する。非ゼロ終了、期限切れ、空出力は失敗。`onFail.transform` があれば同じ入力で一度だけ走らせ、その結果で続ける。無ければ送り先へ渡さず通知する。
7. `output` を適用する。`replaceInput` はスナップショット時に捕まえた欄のハンドルへ書き、読み戻しが一致したときだけ `apply` 行を出す。変換に数秒かかってフォーカスが移っていても、別の欄を書かない。失敗（非ゼロ、期限切れ、書き込み無視、欄の失効）は `onFail.output` があれば同じ結果で一度だけ走らせる。失敗の扱いの全体は [`failure-fallback.md`](failure-fallback.md)。

`--smoke-feed` の終了コードは、ルールが一つでも一致すれば 0（段が失敗しても 0）、どれも一致しなければ 2、設定が不正なら 1。

## Shape

### データ

```swift
// Config.swift  境界。JSON をここで全部検証する。
enum Focus: String, Codable { case textField, any }

enum BuiltinSink: String, Codable { case none, replaceInput, notify }
enum Output: Equatable { case builtin(BuiltinSink), shell(String) }   // JSON は文字列か {"shell"}

struct When: Equatable {
    var app: [String]?     // nil はワイルドカード
    var focus: Focus       // 省略時 .any
}

/// 本来の値と、失敗したとき一度だけ差し替える値。onFail は Value であって Guarded ではない（代替の代替は無い）。
struct Guarded<Value: Equatable>: Equatable { var primary: Value; var onFail: Value? }

struct Rule: Equatable {
    var trigger: String
    var when: When
    var transform: Guarded<String>?  // nil は恒等。transform が無ければ onFail.transform も無い
    var output: Guarded<Output>      // 省略時 .builtin(.none)
}

struct KeypipeConfig: Equatable {
    var rules: [Rule]
    var shellTimeout: TimeInterval   // 既定 30。全シェルの期限
}

// Context.swift  状況のスナップショットと純粋な判定。
enum Focus: Equatable {
    case nothing    // focused element exists but is not a text element (Finder desktop is an AXGroup)
    case text       // AXTextField / AXTextArea with no marked text
    case composing  // text element whose AXTextInputMarkedRange.length > 0
}
/// Opaque handle to the element captured at snapshot time. MacDesktop maps it to the AXUIElement.
struct Field: Equatable { var token: Int }
struct Snapshot: Equatable {
    var app: String?
    var focus: Focus
    var field: Field?   // non-nil when focus is .text
}
func matches(_ when: When, _ s: Snapshot) -> Bool { notImplemented() }   // .composing never reaches here
func select(_ candidates: [Rule], _ s: Snapshot) -> Rule? { notImplemented() }
```

### 境界のポート

```swift
// Desktop.swift
protocol Desktop {   // 原始操作だけ。消去と書き込みの手順は Engine 側の performErase / performWrite に一度だけ書く
    func snapshot() -> Snapshot
    func backspace(_ count: Int)                   // post Backspace tagged with keypipe's eventSourceUserData
    func text(_ f: Field) -> String?               // nil: handle is dead
    func setText(_ f: Field, _ s: String) -> Bool  // false: handle is dead. AXValue; replaceInput and erase-rewrite
    func notify(_ s: String)
}
// MacDesktop.swift   #if os(macOS)。AXUIElement と CGEvent はこのファイルの外に出さない。
// FakeDesktop.swift  JSON で状況と欄の文字を与え、erase/write の呼び出しを記録して出力する。
//   {"app":..,"focusIsTextField":bool,"composing":bool?,"ignoresBackspace":bool?,"fieldText":..}
//   composing && !focusIsTextField は読み込み時に拒否。
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
- フォーカスは bool ではなく `Focus` 3 状態。「テキスト欄でないのに変換中」を型で表せなくする。`composing` と `nothing` はルール作者が名指しするものではないので `when` の値には出さない。
- アプリ固有の癖は bundle id の表で持たない。Backspace 無視は読み戻しで観測して直す（未知のアプリにも効く）。ターミナルが欄に見える件は `when.app` で書き分ける。`AXRoleDescription` などの未検証の判別子に乗る型は作らない。
- AX と CGEvent の型は `MacDesktop` に閉じる。JSON の検証は `loadConfig` だけで行う。boundary-discipline による。
- 変換と外部送信は同じ `shell` 経路を共有し、専用の型を作らない。`log` アクションは消す。laziness-protocol による。

### 意図的にやらないこと

- 選択テキスト。
- 変換や送り先の名前付き再利用（同じ `transform` を複数ルールで共有する定義）。同じ文字列を三回書くようになったら足す。
- 多段パイプライン記法。シェルのパイプで書ける。
- 設定のホットリロード。TOML/YAML。

## Synthesis decision

改訂 2 まで。arena は回さず候補を自分で比較した。候補 A（採用）`when → transform → output` の固定の組。候補 B `steps: [...]` の自由なステップ列は、シェルのパイプと二通りの書き方になるので不採用。候補 C トリガー検出だけして状況を環境変数で渡す極小案は、欄の読み書きができないので環境変数の部分だけ取り込んだ。

改訂 3（2026-10-31）。コンテキストと実行モデルの妥当性を問う arena を回した。候補 2 本、ともに Claude Opus（別系統の判定役はこのホストに無く、判定は置かなかった）。候補 1 は最小の形、候補 2 は領域を型で明示する形。基準は「測定事実に反しない」「ルール作者が設定だけで `$1` の中身を言える」「未検証の判別子に乗らない」「同じことに二通りの書き方を作らない」「改訂 2 からの差分の小ささ」。

両候補が一致した点（そのまま採用）。

- フォーカスは bool ではなく列挙。`nothing` は nil ではなく役割から導く。`composing` は `AXTextInputMarkedRange` から取る。
- 変換中のトリガーは発火しない。確定を待つ案は、tap が見た `@@@` と欄の `＠` が合わないので両候補とも捨てた。
- `focus: any` のルールは欄を読まない。テキスト欄でないときは Backspace も送らない。レビュー既定「`focus: any` でも消す」をテキスト欄のときだけに狭める。
- ターミナルで `textField` ルールが画面全体を読む問題は、実装前の今は `when.app` で書き分ける。

基底は候補 1。差分が小さく、癖をコードに名指しで溜めない。候補 2 から移植した点。

- 欄のハンドル（`Field`）をスナップショット時に捕まえ、`replaceInput` と書き戻しはそこへ書く。候補 1 の `apply(sink, text)` は書き先が無く、遅い変換の間にフォーカスが移ると別の欄を書く。
- `replaceInput` は `focus: textField` でだけ許す設定エラー。列挙の入れ子（候補 2 の `Scope`）までは持ち込まず、`loadConfig` の検査一つにする。
- 読み戻しの前に、値が変わるのを期限まで待つ。候補 1 の「即座に二回読む」は、Backspace がまだ処理されていないと書き戻してしまい、遅れて届いた Backspace が利用者の文字を消す（候補 2 の指摘、推測）。

候補 2 から退けた点。

- bundle id の癖表。測定済みの癖でアプリ名が要るものは無く、表に無いアプリの同じ癖は直らない。
- `focus: terminal` と「最後の Return 以降に打った行」の追跡。矢印・貼り付け・クリックで不明になり、上限が重い。iTerm2 の入力は `tmux capture-pane` をシェルで書けば足りる。
- webhook の組み込み。`curl` の面を設定キーに写す二通り目の書き方になる。JSON 本文に `jq` が要る上限は Usage に書いた。
- `insert` と `clipboard` の組み込み。実例が無く、`pbcopy` で書ける。

## Tradeoffs accepted

- 変換と送信がシェル一本である代わりに、利用者はクォートを自分で書く。`$1` を用意してクォート事故を減らす。
- 旧スキーマ（`action.type`, `context.appBundleId`）との互換は捨てる。
- `transform` と `output.shell` は同期実行。`claude -p` の数秒間、次の発火は待たされる。キー取得自体は止めない（発火は tap のスレッドではなく直列キューで走らせる）。
- 日本語入力モードではトリガーが効かない。代わりに変換中のかなを誤って消さない。
- `focus: any` のルールは欄の文字を受け取れない。代わりに `$1` の中身が設定だけで決まり、ターミナルで画面全体を書き戻す経路と、欄以外での Backspace が無くなる。
- ターミナル除けは設定の `when.app` か先行ルールで書く。代わりに未検証の判別子に乗る型を作らない。

## 実機で確かめた前提（2026-10-31、macOS 26.6）

手順と観測は [`verification-plan.md`](verification-plan.md) の表、プローブは `.claude/skills/verify-keypipe-rules/probes/`。設計に効く結論だけ書く。

- listen-only の CGEventTap は `System Events` の合成打鍵を受ける。Input Monitoring は不要で、Accessibility だけで tap と AX が動いた。
- 自分が post した Backspace は自分の tap にも届く。`eventSourceUserData` に印を付けて無視する。
- TextEdit の本文は AXTextArea で `AXValue` は読み書きできる。CotEditor も同じ。
- ターミナル（iTerm2）のプロンプトは **AX 上テキスト欄として見える**。AXTextArea で `AXValue` は画面全体（約 3,800 文字）。`focus: textField` の既定ではターミナルで `@@@` を打つと画面全体が入力になる。AXRole では TextEdit と区別できない。判別ができるまで、ターミナル向けのルールは `focus: any` にして欄の文字を使わない（上の `;;;` の例）。
- 合成 Backspace はアプリ依存。CotEditor では消える。TextEdit はプローブ（2026-10-31）では無視したが、デーモン本体が post した Backspace は届いた（2026-11-01、M1/M2 の 4 発火すべて `erase 3` のみで `erase-rewrite` 無し）。差の原因は未特定。手順 5 の読み戻しと `AXValue` の書き戻しは無視するアプリ向けに残す。
- 「何もフォーカスしていない」は nil ではない。Finder のデスクトップでも `AXFocusedUIElement` は `AXGroup`（`AXFocused=1`）。役割から `nothing` を導く。
- IME 変換中は判別できる。TextEdit の欄は `AXTextInputMarkedRange` を持ち、ATOK で変換中は長さが正、Escape 後は 0。`AXValue` には変換中の文字が既に入る。
- ATOK が有効だと合成打鍵がローマ字変換される。利用者の espanso に `@@` トリガーがあり `@@@` と取り合ったが、2026-11-01 に利用者が `@@` を外し、espanso を動かしたまま実機検証が通った。トリガーの接頭辞を共有しない限り共存できる。

## リスク（未検証）

- 一部アプリ（Electron 系）は `AXValue` の書き込みを無視する。`replaceInput` は書き込み後に読み戻し、失敗したら「全選択してペースト」に落とす。
- ターミナルをテキスト欄から外す判別。`AXRoleDescription` が TextEdit では取れ、iTerm2 ではエラー（-25212）だったのが候補。2 種以上のターミナルとブラウザの欄で測ってから型にする。
- TextEdit が合成 Backspace を無視する原因と、ブラウザの欄での挙動。iTerm2 が合成 Backspace を受けるか。
- TextEdit 以外のアプリが `AXTextInputMarkedRange` を出すか。出さないアプリでは変換中を `text` と見て、かなを消す。
- Backspace 後の読み戻しの待ち（200 ms）の妥当性。M1 では足りた。
- 測定済み（2026-11-01）。tap はアプリより先にキーを見る。直列キューへの非同期だけでは足りず、M1 で欄が `HELL@@` になった（最後の `@` が入る前に読んで消した）。消す前にトリガーの接尾辞が揃うまで最大 100 ms 待って直した（`waitForTrigger`、`focus: any` の消去でも同じ）。

## 検証のための追加契約

`.claude/skills/verify-keypipe-rules/` が前提にする振る舞い。設計本文への追加なのでレビュー対象。

- 未知のキーを持つ設定は拒否する。旧スキーマ（`action`）が「何もしないルール」として黙って読み込まれるのを防ぐ。空の `transform` と空の `output.shell` も設定エラー。
- 出力行は一行ごとに flush する。検証は各行を期限内に観測できることを契約とする。
- `transform` の出力は末尾の改行を一つだけ落とす。`claude -p` や `echo` が付ける改行を欄に入れないため。
- `focus: textField` は AX のテキスト欄とテキストエリア（複数行）の両方を含む。
- `--context <json>` で `FakeDesktop` に状況を与える。打ったキーは `fieldText` の末尾に足され、erase は末尾から消す。`composing` と `ignoresBackspace` で変換中と Backspace 無視を再現する。
- `--probe` は Accessibility の許可と現在のスナップショットを JSON 1 行で出す。`focus` は `textField` / `composing` / `none`。利用者が `when.app` の bundle id を調べる用途も兼ねる。
- 発火の各段で `keypipe matched / nomatch / composing / erase / erase-rewrite / transform exit / apply / output-shell exit / field` の行を出す。形式は `SKILL.md` の表。

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
