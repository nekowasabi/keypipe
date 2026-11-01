# 拡張点の設計（条件・出力・voice-switch 境界）

状態: 実装済み（keypipe `feat/extension-architecture`、voice-switch `feat/keypipe-delivery`）。スケッチは設計時の記録として残す。実装との差分は末尾の「実装メモ」。型とシグネチャは `docs/design/extension-sketch/` にある。`Sources/` の外に置いているので、ビルドには入らない。2026-11-01、/architect で3案を比較して1案にまとめ、ateam review（Claude・Codex・Grok の3名、相互検証つき）の指摘を受けて折衷案に改めた。

## Problem

ダッシュボード（`docs/ideas/IMPLEMENTABILITY-2026-11-01.md`）で洗い出した条件と機能を、1件ずつ足していきたい。そのとき、足した1件の変更がほかの場所に広がらない形にしたい。

今は1件足すと複数の場所を同時に直すことになる。
- **条件 `when.url` を足す場合**: Config の許可キーとパース、`When`、`Snapshot`、`MacDesktop`・`FakeDesktop`・`LineDesktop` の `snapshot()`、`matches()` の5〜7か所。
- **出力を足す場合**: `BuiltinSink`、`parseOutput` の妥当性検査、`Engine.apply` の switch、`Failure`。

`Snapshot` は発火のたびにすべての事実を先に取るので、遅くて Automation 許可が要る事実（ブラウザの URL）を素直に足すと、全ルールの発火で AppleScript が走る。

voice-switch との境界は「config に書いたシェル文字列が `keypipe --line` を叩く」暗黙の約束しかない。`--line` は失敗しても exit 0 で原文を返すので、voice-switch は「置換された / 配送した / 失敗した / どのルールにも当たらなかった」を区別できない。

守る制約（ユーザー確認済み）:
- 既存の config キーと CLI の互換。特に `--line` の「stdout＝新しい行、exit 0/2/1」は zsh widget が依存している。
- 未知キーの拒否は続ける。受け付けるキーは、定義している場所から導出する。
- background job は rule を配列の index で渡す。
- テストの土台は FakeDesktop＋`--smoke-feed`。verify-keypipe-* が照合する transcript 行は変えない。
- 安全ゲートは入力欄を読む前に評価する。
- 依存ゼロの単一バイナリ。1改善1PR。

レビューで分かった制約（2026-11-01、3名が一致）:
- 入力欄の読み直し・トリガー消去・書き込みは、欄を繰り返し読む前提で動いている（`performErase`・`performWrite` の待ち合わせ）。verify-keypipe-rules の R4c・R4e・R4f は、読むたびに Backspace や遅延書き込みが1段ずつ進むことを確かめている。この部分を「1回読んでメモする」仕組みに移すと壊れる。
- 既存テストは `When(focus:)` を直接組み、verify-keypipe の V4a は `Context.swift` をパス指定で照合する。`When` 型を消すと、挙動を変えなくてもテストが通らない。
- 端末が前面だと今は hotkey を含む全ルールが止まる。この組み込みゲートを空にして移すと、端末系の検証（B4）が落ちる。

## Usage (caller's view)

### `when.url` を1件足す（この設計の仕様）

利用者が書く設定:

```json
{ "rules": [
  { "trigger": "@@@",
    "when": { "app": ["com.google.Chrome", "com.apple.Safari"], "focus": "textField", "url": "*://github.com/*/pull/*" },
    "transform": "claude -p 'PR のコメントとして整える。結果だけ'",
    "output": "replaceInput" },
  { "trigger": "@@@", "when": { "focus": "textField" }, "transform": "tr a-z A-Z", "output": "replaceInput" }
]}
```

開発者が変えるファイルは2つだけ。

| ファイル | 変更 |
|---|---|
| `Sources/keypipe/Facts.swift` | `case url` を1行。`spec` に `FactSpec(cost: .slow)` を1行。`readMac` に osascript の分岐を1つ。3つとも網羅的な switch なので、1つ書き忘れるとビルドが落ちる |
| `Tests/keypipeTests/FactsTests.swift` | 「GitHub のときだけ一致する」「安い条件で外れたら URL を読まない」「読めなかったら止まる」の3本 |

これで次のことが自動で揃う。
- `when` と `deny` が受け付けるキー（`url` が通り、`urll` は今までどおり `unknown key urll` で落ちる）
- fake コンテキストの `"facts": {"url": ...}`（FakeDesktop.swift は編集しない）
- 評価順（遅い事実は最後に読む）

URL を読むのは、同じトリガーのルールが `url` を条件に持ち、そのルールの安い条件（app・focus）がすでに通ったときだけ。1回の発火の中では1回しか読まない。上の例で TextEdit が前面なら、osascript は1回も走らない。

**URL が読めなかったとき**（Automation 未許可、osascript の期限切れ）は、「一致しなかった」ではなく「読めなかった」として、その発火を止めて通知する。次のルール（上の例なら大文字化）には進まない。利用者が GitHub 用の整形のつもりで打ったトリガーが、別の変換に化けるのを防ぐため。

テストの書き方:

```swift
let fake = FakeDesktop(app: "com.google.Chrome", focus: .text, fieldText: "x@@@",
                       facts: [.url: "https://github.com/a/b/pull/1"])
XCTAssertEqual(engine.fire(.text("@@@")), .replaced(rule: 0, text: "...", viaFallback: false))
// 安い条件で外れたら読まない
XCTAssertFalse(fakeOnTextEdit.reads.contains(.url))
// 読めなかったら止まる（facts に url が無い fake）
XCTAssertEqual(engineNoUrl.fire(.text("@@@")), .unreadable(fact: .url, reason: "not available"))
```

smoke テストでは、`--context` の JSON に `"facts": {"url": "https://github.com/x"}` を足すだけで試せる。

### 出力 `typeText` を足す（PR3 のあと）

`Sinks.swift` に case を1つ、`spec` に `SinkSpec(failures: [.gone, .unsupported], detachable: false)` を1行、`perform` に分岐を1つ足す。あとはテストを1本。
- onFail を付けられるかは `failures` が空でないこと、background の代替先にできないことは `detachable` から導かれる。`parseOutput` と `Engine.apply` は spec を読むだけなので編集しない。
- **`--line`（zsh・音声）経由では `unsupported` の失敗として返す。** 打ち込む先の画面が無いのに「成功」と返さない。`onFail: {"output": "notify"}` で逃がせる。

### voice-switch から呼ぶ（PR1）

voice-switch の設定:

```json
{ "keypipe": { "binary": "/usr/local/bin/keypipe", "config": "~/.config/keypipe/config.json" },
  "macOS": { "actions": [
    { "name": "けいご", "wakeWords": ["けいご"], "keypipe": "@@@keigo", "superwhisperMode": "voice_switch" } ] } }
```

voice-switch は argv を自分で組み立て（シェルを通さない）、`keypipe --config C --line @@@keigo --report --app <対象>` を呼ぶ。stdout の1行 JSON の `outcome` で振り分ける。

| outcome | voice-switch の動き |
|---|---|
| `replaced` | Superwhisper のモード切替が成功していれば `pasteDictation(text, target)` で貼る。貼れなかったら clipboard に入れて通知する |
| `delivered` / `started` | ログだけ |
| `failed`（stage と failure 付き） | ログと HUD。何も貼らない。原文も貼らない |
| `nomatch` / `blocked` / `unreadable` / `noinput` | ログだけ。何も貼らない |

- `superwhisperMode` は keypipe 配送の action では**必須**（設定の読み込み時にエラー）。自動貼り付けが残っていると、原文と整形文が二重に貼られるため。
- `--report` を付けない `--line` は、今とバイト単位で同じ。
- 音声経路では `url` などの live の事実を読まない。voice-switch が対象アプリを前面に戻すのは keypipe の実行後なので、読んでも別のウィンドウの URL になるため。`when.url` のルールは音声からは一致しない。
- ウェイク語だけで本文なしの呼び出し（M3）は今回の範囲外。実デスクトップへの外部 fire（M2）と一緒に後で設計する。

## Shape

### 方針（折衷案 C）

表にするのは **条件に使う事実** と **出力** の2つだけ。入力欄の読み直し・トリガー消去・書き込み（`performErase`・`performWrite`）と、組み込みゲート（composing・terminal）の実行形は今のコードのまま触らない。環境変数も今どおり `KEYPIPE_APP` だけ（`KEYPIPE_<FACT>` は後回し）。

```
Facts.swift   FactName（表）/ FactSpec / Matcher / Conditions / FactSheet / Mac の読み手   ← 条件の事実だけ。欄のテキストは含めない
Sinks.swift   Sink（表）/ SinkSpec / Failure / Output / ShellOutput
Desktop.swift 今の5メソッドはそのまま。fact(_:) と typeText(_:) を既定実装つきで追加
Engine.swift  fire -> FireResult。ゲート → 選択 → 消去と取得（今のまま）→ run
Config.swift  When 型は残す（focus は今の typed enum）。事実の条件を Conditions として中に足す
Report.swift  FireResult を JSON 1行にする（--report）
Context.swift 残す（V4a が照合する Snapshot と matches はここ）
```

### 判断の要点

- **1つのリストから導出する**: `when` と `deny` のキー、ネイティブ出力の名前、fake の `facts` のキーは、`FactName` と `Sink` の `allCases` と `spec` から作る。表に追加して読み手を書き忘れると、網羅的な switch でビルドが落ちる。
- **事実は発火ごとに必要なぶんだけ読む**: `FactSheet` が1回の発火のあいだだけ条件の事実を持ち、メモする（読めなかったことも メモする）。評価はコストの順（構造 < 安い < 遅い）で、外れたらそこで止める。**欄のテキストは事実ではない**ので、シートは欄を一度も読まない。消去と書き込みの待ち合わせは今どおり欄を繰り返し読む。
- **照合はすべてグロブ**: `app` も含めて fnmatch で照合する。バンドル ID に `* ? [` は出ないので、既存の設定の意味は変わらず、`com.apple.*` が書けるようになる。
- **読めなかった事実は「不一致」ではない**: `Conditions.evaluate` は match / noMatch / unreadable の3値を返す。unreadable なら、その発火を止めて通知する（次のルールに落ちない）。`deny` の評価で unreadable なら、安全側に倒して止める。
- **ゲートは今の位置のまま、2つ増やす**: `Engine.fire` の先頭で composing・terminal（今のまま）に続けて、secure（M7、`Snapshot.secure`、既定で有効）と、利用者の `deny`（M6）を評価する。どれも欄を読む前。terminal は M18 として「`focus: textField` のルールだけ止める」に緩める（`focus: any` の hotkey は端末前面でも動く）。transcript の `keypipe terminal <t>` と `keypipe composing <t>` は今と同じ文字列。
- **`deny` に遅い事実を書けるのは `app` と組んだときだけ**: `{"deny": [{"app": ["com.google.Chrome"], "url": "*://bank.example.com/*"}]}` は通るが、`url` だけの `deny` は設定の読み込みで落とす。メモ帳で打つたびにブラウザへ問い合わせが走るのを防ぐ。
- **遅い事実を読む間に前面が変わったら消さない**: 消去の直前にもう一度前面アプリを見て、変わっていれば Backspace を送らずに止める（実機で起きるかは未検証。起きなければ外す）。
- **ネイティブ条件と shell 条件の線引き**: デスクトップの事実をグロブで見る条件と、欄を読む前やルールを選ぶ前に決まる必要がある条件は `when` に書く。入力の中身・正規表現・時刻や git などデスクトップ外の状態は shell に書く。正規表現・否定・事実をまたぐ OR はネイティブに入れない。
- **結果の型は1つ**: `Engine.fire` は `FireResult`（blocked / noMatch / unreadable / noInput / replaced / delivered / started / failed）を返す。`--line` の exit、`--smoke-feed` の hits、`--report` の JSON、voice-switch の判断は、すべてこの値から作る。background の起動に失敗したら `started` ではなく `failed(stage: spawn)`。
- **rule の同一性は入れない**: Job は今までどおり index を持つ。`JobRequest` に config のパスと**親が読んだバイト列**の両方を入れ、子はファイルを読み直さない。index は親が照合したルールの並びを必ず指す。jobs.log の `job rule N from <path>` 行は今のまま。

### インターフェースの深さ

- `Desktop` は今の5メソッドに、既定実装つきの2メソッドを足すだけ。事実や出力を足しても、3つの実装は変わらない（Mac の読み手は `Facts.swift` 側）。
- Engine の公開面は `fire -> FireResult` と `run(Job)` だけ。
- 拡張する人が触るのは、表の1行と、その事実の読み手（または sink の perform）だけ。

## Synthesis decision

- **進め方**: 構造の違う3案（1: Swift レジストリ、2: 事実をデータとして公開、3: 版付き要求・応答プロトコル）を Claude（opus）で並列に作り、候補2を基盤に候補1・3から移植して1案にした。他系統モデルによる相互審査は省いた。
- **レビュー後の変更**: ateam review で、候補2の「欄のテキストも事実としてシートで1回読む」形が R4 系の検証を壊すこと、`When` 型と `Context.swift` を消すと既存テストが通らないこと、組み込みゲートがスケッチで空だったことが分かった。Grok の「表を足す前に今の契約を固定すべき」という批判を受け、表の対象を条件の事実と出力に絞り、欄まわりとゲートの実行形は触らない折衷案に改めた。
- **採った指摘**: typeText は `--line` で失敗として返す。URL が読めなければその発火で止める。`deny` の遅い事実は `app` と組んだときだけ。Superwhisper のモードを必須にする。background の起動失敗を結果に出す。`focus` の値検査は必須のまま。`When` 型と `Context.swift` は残す。
- **見送ったもの**: 候補1の種類ごとの型とファイル（公開面が大きい）。候補3の rule id と JSON 要求（今の需要には要らない）。候補1から一度移植した `configDigest`（デーモンは config を再読込しないので、編集のたびに全 background 発火が止まる）。
- **3案が一致した点**: `FireResult` を1つにする。`--line` の既定出力は変えない。voice-switch は argv を自分で組んで JSON を読み、`replaced` のときだけ貼る。遅い事実は遅延取得してメモする。fake JSON に `facts` を持たせる。

## Tradeoffs accepted

- 入力欄まわり（読み直し・消去・書き込み）は今の作りのまま残る。選択範囲（M5）を足すときに、改めてそこを設計する。
- 事実を1つ足すとき、Facts.swift の中の3つの switch（case・spec・readMac）を同時に触る。その代わり、1つ忘れればビルドが落ちる。
- 照合はグロブと any-of だけ、という表現力の上限を受け入れる。
- URL を条件に持つルールは、トリガーを打ってから消えるまでに最大1秒空く。その間に打った文字でトリガーが消え残ることがある。URL ルールだけの退行として受け入れる。
- voice-switch 側に report の写しの型を手で持つ。その代わり、同じ golden 行を両リポのテストが読み、ずれたらテストで落ちる。
- README の `when` キー一覧は手書きのまま。足し忘れてもテストでは落ちない。
- `KEYPIPE_<FACT>` は出さない。shell で URL が要るときは、当面 transform の中で osascript を呼ぶ。

## Alternatives considered

- **候補1: 種類ごとの型レジストリ**: 1件が1ファイルに収まり、局所性はいちばん高い。しかし公開面が大きく、`Rule` の Equatable を失い、基盤 PR が最大になる。
- **候補3: 版付き要求・応答プロトコル**: すべての入口が1つの型でつながるが、rule id・wire の版・要求 JSON と、今は使わない仕組みを先に入れることになる。
- **候補2の原形（欄のテキストも事実にする）**: 表は2枚で済むが、R4 系の検証と既存テストを壊す。レビューで退けた。
- **Grok 案（契約を先に固定し、表は後回し）**: いちばん安全だが、「1件足すとき1か所で済む」目的が後回しになる。折衷案は、壊す範囲を Grok 案と同じに抑えつつ、条件と出力の追加だけは1か所にする。
- **config で事実を定義する**: ゲートが欄より先に評価される保証を keypipe が持てない。

## Open questions and risks

1. Automation 許可はプロセスごとに付く。デーモン自身が初回の URL 取得で許可ダイアログを出す方針だが、osascript の期限（1秒）でダイアログ中に止めると許可が取れない恐れがある（推測）。**PR2 の前に実機で確かめる。**
2. 遅い事実を読む間に前面アプリが変わる競合が、実際にどのくらい起きるか。消去直前の再確認で足りるかを実機で見る。
3. Facts.swift の Mac 読み手は、単一モジュールの Swift では外から直接呼べてしまう。レビューに任せる。
4. M5（選択範囲）の書き戻し検証は未設計。AX の選択テキストに書くと選択が畳まれ、読み直すと空になる。
5. M2（実デスクトップへの外部 fire）はデーモンと同じ欄に2か所から書き込む競合がある。M3 と一緒に後で設計する。

## Next implementation step

1. **PR1**: `FireResult` と `--report`、background 起動失敗の結果化、`JobRequest` に config のバイト列、golden 行。voice-switch 側に `keypipe` 配送（`superwhisperMode` 必須、貼れなければ clipboard＋通知）。
2. **PR2**: `Facts.swift`（app・focus のみ）と `Conditions` を `When` の中に足し、`FactSheet` の遅延取得、`deny`、secure ゲート、terminal ゲートの緩和（M18）、消去直前の前面再確認。最初の事実として `url`。着手前に未決1を実機で確かめる。
3. **PR3**: `Sinks.swift`。`Engine.apply` の switch と `parseOutput` の sink 名を消す。typeText が要るときに足す。
4. **後で**: M5（選択範囲）、M2・M3、`KEYPIPE_<FACT>`。

## 実装メモ（2026-11-01）

設計から変えた点:

- **M18 は hotkey だけ**: 端末前面で動くのは `focus: any` の **hotkey** ルールだけにした。文字トリガーは zsh widget が受け持つので、デーモンも動かすと同じトリガーで二重に発火するため。
- **live の事実が無い経路では「無い」（absent）**: `--line`（zsh・音声）と background job の desktop は事実を読めない。これを「読めない」（unreadable）にすると URL ルールが毎回その発火を止めてしまうので、「その事実は無い」として不一致に倒し、次のルールに進めるようにした。ブラウザ以外のアプリの URL も同じ。「読めない」で止めるのは、ブラウザが前面なのに読めなかったときだけ。
- **事実の値は配列だけ**: `"app": "x"` を不正とする既存のテストに合わせ、`url` も文字列の配列にした。
- **`--report` に `rule` を入れた**: どのルールが動いたかをログで追えるように、一致したときは index を付ける。
- **ネイティブ出力が fallback なしで失敗したら結果を通知**: 今までは replaceInput だけだった。typeText も同じく結果を失わない。
- **`KEYPIPE_<FACT>` は出していない**（設計どおり後回し）。

確かめたこと（PR1〜PR3 の時点）: `swift test` 61 件成功、verify-keypipe-rules `--no-live` 62 件、verify-keypipe-terminals `--no-live` 35 件、verify-keypipe `--no-live` 25 件、verify-keypipe-trigger の 254 入力、voice-switch の url-actions 106 件（静的変異 33 件を含む）。実機の M8（Chrome の Automation 許可）と M9（typeText を実際に打つ）、voice-switch での音声からの貼り付けは未確認。

### ateam review（2026-11-01、Claude・Codex・Grok）で直したこと

- voice-switch の `runCapturing` の期限が全体を囲んでいなかった（P1）。起動から stdout の EOF まで1つの期限にし、SIGTERM のあと SIGKILL。TERM を無視する子・stdout を握る孫・stdin を読まない子の3経路をテストに足した。
- 遅い事実を読んだ後の再確認が app だけだった（P2）。focus・パスワード欄・欄がまだトリガーで終わるかも取り直し、変わっていれば `blocked front-changed` で止める（--report でも nomatch と区別できる）。
- keypipe の failed が voice-switch の HUD で done になっていた（P2）。`actionFailed` で失敗表示にし、failed は通知する。
- deny の事実が読めないとき黙って止まっていた（P2）。理由を通知し `unreadable` を返す。
- typeText: 修飾キーを押したままだと Ctrl/Cmd 付きで打たれる（P2）。合成イベントのフラグを空にした。Mac とフェイクで「打てる場所」をそろえた（テキスト欄と端末だけ）。
- URL 取得: ウィンドウが無いとき「Automation を許可して」と誤った通知が出た（P3）。Automation 拒否（-1743）だけを unreadable にした。
- golden 行の網羅が自己採点だった（P2）。`FireResult.Kind` で全種類をそろえることを強制し、voice-switch 側は keypipe の golden ファイルと突き合わせる。

残した点（判断して残した、または未確認）:

- `JobRequest.configBytes` が nil のときファイルを読む分岐は残した。動いているデーモンが古いバイナリのまま、再ビルドした新しい子を起動する更新の合間のため。
- P4 は今ある事実（app・url）の全組み合わせだけ。cheap の事実はまだ無い。P8 の id 一覧は手書きの標本。
- 端末前面ではパスワード入力（sudo など）を検知できない。`focus: any` の hotkey で typeText を使うと打ててしまう。
- typeText の Unicode イベントが日本語 IME オンのときにどう変換されるかは未確認（M9 で IME オンも試す）。書記素クラスタを2つのイベントに分ける可能性もある（サロゲートペアは分けない）。
- 初回の Automation 許可ダイアログ中に osascript を 1 秒で止めたとき許可が取れるかは、実機で未確認（M8）。

### 確認レビュー（2026-11-01、2回目）で直したこと

- 遅い読みの後の確認が欄を1回だけ読み、遅れて届くトリガーの打鍵を待たずに正常な発火を止めていた（修正で入った回帰、3名一致）。速い経路と同じ `waitForTrigger` で待つ。R12h とテストを追加。
- 同じアプリで別のテキスト欄へ移ったことを検知できなかった（前からの穴、3名一致）。`Desktop.sameField` を足し、Mac は AX 要素を `CFEqual` で比べる。
- URL 取得で Automation 拒否以外のエラーを「URL が無い」にしていたため、`deny` が素通りしえた（修正で入った回帰）。「ウィンドウ・タブが無い」（-1728, -1719）だけを absent にし、ほかは unreadable で止める。
- typeText は前面がテキスト欄か端末でないと unsupported になる。AXComboBox や IME 変換中など、以前は打てた所で打てなくなる可能性がある（意図した契約。M9 で確かめる）。

### 3回目のレビューで直したこと

- URL 取得の AppleScript が構文エラー（`on error message m number n`）で、実機では URL 条件が一度も働かなかった（P1、3名一致）。`on error m number n` に直し、スクリプトを `osacompile` でコンパイルし、-1728・-1719 は空、-1743・-600 はエラーになることを確かめるテストを足した（旧スクリプトでは落ちることを確認）。フェイクの事実を使う検査ではこの経路を通らないので見逃していた。
- 遅れて届く打鍵を待つ間（最大 0.1 秒）に欄が移る窓を、待った後にもう一度 app・focus・パスワード欄・同じ欄かを確かめて閉じた。

未確認のまま残るもの: 実機の Chrome・Safari で `CFEqual` が同じ欄を同じと判定するか、M8（URL ルールと Automation 許可）、M9（typeText、IME オン）、voice-switch からの実際の貼り付けと HUD。

### 4回目・5回目のレビュー

- 4回目: 3回目の製品修正（AppleScript の構文、待った後の再確認）は3名とも正しく回帰なしと判定。新しいテストの移植性（Chrome の無い Mac、osascript の無い環境、出力未確認、.scpt の残留）を `eb3b447` で直した。
- 5回目: `eb3b447` は3名とも確定指摘なし。残した P3: Chromium 用の問い合わせ文（`URL of active tab of front window`）はテストでコンパイルしていない（Chrome の無い Mac で誤って落ちないよう、必ずある Safari だけをコンパイルしている）。実機の M8 で確かめる。

### 最終確認レビュー（6回目、相互検証が成立）

- `2a1fd05`（入っている Chromium 系ブラウザのスクリプトもコンパイル）を含め、両ブランチに確定した P0〜P2 は無し。Claude と Codex が互いの指摘を検証し、Grok が両方を確認した。
- 指摘された P3 のうち2件は直した: テストのブラウザ一覧に Canary が抜けていた（追加）。voice-switch の `F_SETNOSIGPIPE` が Darwin 専用なのに Linux の url-test でもコンパイルされる（`#if canImport(Darwin)` で分け、Linux では SIGPIPE を無視する）。
- 残した P3: コンパイル検査は構文とアプリの辞書までで、問い合わせ文の意味（本当に URL が返るか）は確かめられない。実機の M8 で確かめる。

### 探索的改善（2026-11-01 夜、各段を ateam review にかけた）

keypipe:

- `b44fc40` URL を読めるブラウザの一覧を1か所にし、テストはその一覧を（入っているものだけ）コンパイルする。
- `dbb4e06`・`2e33ff3`・`bd121ba`・`a0a9081` 引数を1回だけ解析する。`--help` は使い方を出して 0。知らない引数、値の無いフラグ、`--line` 無しの `--report`/`--app`、同じフラグの2回は、使い方を出して 2 で止まる（以前は黙ってデーモンが起動した）。値がフラグ名と同じでも値として読む（`--line --report` の `--report` はトリガー）。R2q・R2r・R2u・R2v・R2x。
- `b3651f0` `app`/`url` の空の一覧を設定不正として拒否する。`{"app":["com.google.Chrome"],"url":[]}` の deny は何も止めずに素通りしていた。
- `a00a5e8`・`211bb3e`・`81fb62d` ほか Linux でビルドできなかった Shell.swift を直した（`5ae1475` から）。Linux のジョブが親の fd を受け継いでいた（glibc に `POSIX_SPAWN_CLOEXEC_DEFAULT` が無い）ので、`/proc/self/fd` に並ぶ開いた fd を閉じる（65536 までの走査では fd 70000 が漏れた）。一覧を取れないとき（`/proc` が無い chroot など）はジョブを起動しない。setsid と fd の継承（低い番号と fd 70000）を ShellTests で固定し、R1d で Docker の `swift:6.0` に build と `swift test` をかける（`--init`、`--ulimit nofile=131072`、コンテナ内の `timeout -k 30 900`。docker の CLI は SIGALRM を無視するので外側の上限は効かない）。
- `17f781d`・`f8bead6`・`8a95fa7` README: 音声の節に voice-switch の keypipe 配送の例。日本語版に抜けていた `when.url`・`deny`・パスワード欄・`typeText`・端末の hotkey 例外。設定が不正なとき widget が黙ることと、理由の確かめ方。

voice-switch（`feat/keypipe-delivery`）:

- `1836fec`・`79c6dca`・`9857296` `runCapturing` の stdout を、`poll` で回す読み取りスレッドで集める。Linux の `readabilityHandler` は EOF を取りこぼしていた。期限の後は読むのをやめて読み取り端を閉じ、子孫の出力を溜めない。
- `4f18b72` keypipe の報告が読めないときに通知する。`7b45b0f` `keypipe.binary`/`config` が絶対パスか `~` でなければ読み込み時に拒否する。
- `2a62a7c`・`7b0329a` `make url-test-linux`。verify-voice-switch-mac に keypipe 配送の検証項目（KD1〜KD6）を足し、KD1 と KD4 をテストで押さえた。

残したこと: Linux で fd の一覧を取ってから spawn するまでに別のスレッドが開いた fd は漏れる（Linux ではデーモンが動かないので、glibc 2.34 の `closefrom` 系は使わない）。fd 70000 の検査が効くのは上限を上げた R1d だけ。`Term` は大文字と小文字を区別して照合する（`com.google.chrome` と書くと `com.google.Chrome` に一致しない）。照合の意味を変えるので、利用者の判断に残す。`--line ""` は exit 1、値の無い `--line` は exit 2 のまま。
