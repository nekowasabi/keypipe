# keypipe 検証計画と調査結果

2026-10-31 時点のまとめ。実装前。次の作業は Mac で行う。

## 目的

テキスト欄にフォーカスがあるときにトリガー（例 `@@@`）を打つと、欄の文字を差し替え可能な変換（シェルスクリプト、`claude -p`、API 呼び出し）に通し、結果を差し替え可能な送り先（欄の置換、tmux、Herdr、Grok Bot、CotEditor、スクリプトの引数）へ渡す。状況と処理は設定ファイルだけで書く。選択テキストは扱わない。対象 OS は macOS のみ。

## 決まっていること

振る舞いの正本は [`context-rules.md`](context-rules.md)（改訂 2）。要点だけ再掲する。

- ルールは `trigger` + `when`（前面アプリ、フォーカス種別）+ `transform`（任意のシェルコマンド、省略可）+ `output`（組み込みか `{ "shell": ... }`）。
- 組み込みの送り先は `replaceInput` / `insert` / `clipboard` / `notify` / `none`。外部の送り先は全部 `output.shell` で書く。
- 変換と `output.shell` は入力を stdin、`$1`、`KEYPIPE_INPUT` で受ける。前面アプリは `KEYPIPE_APP`。
- 発火手順は固定。トリガー一致、`when` でルール選択、Backspace で消去、欄を読む、変換、送り先へ適用。
- 旧スキーマ（`action`, `context`）との互換は持たない。

レビューで決めた既定（`context-rules.md` へ反映済み）。

- 長いトリガーのルールがどれも `when` を満たさないときは、短いトリガーへ落ちず何もしない。
- `focus: any` のルールでも打ったトリガーは Backspace で消す。
- 空の `transform` と空の `output.shell` は設定エラー。設計本文に一行足す。
- 出力行は一行ごとに flush し、期限内に観測できることを契約にする。
- 設計の「Linux で feed 経路を維持」は「Linux の feed 経路は単体テスト用」と読む。検証の合否は Mac で出す。

## 検証スキル

`.claude/skills/verify-keypipe-rules/`（`SKILL.md`, `verify.sh`, `features/`）。

| ID | 内容 | 方法 |
| --- | --- | --- |
| R0a/b | macOS、swift | doctor |
| R1a-c | build、`swift test`、`swift-format lint --strict` | build |
| R2a-g | 設定の境界（不正な設定の拒否、最小ルールの受理） | 偽 Desktop |
| R3a-d | ルール選択（focus、app、不成立、設定順） | 偽 Desktop |
| R4a/b | トリガーを消してから欄を読む | 偽 Desktop |
| R5a-c | 変換の入力経路、末尾改行、失敗時 | 偽 Desktop |
| R6a-c | `output.shell` への受け渡し、実 tmux | 偽 Desktop + tmux |
| R7 | 日本語 | 偽 Desktop |
| M0-M4 | Accessibility、TextEdit での置換と送信、Finder で不発火、iTerm2 の観測 | 実機 |

偽 Desktop は `keypipe --config C --context X.json --smoke-feed KEYS`。実機は daemon を起動し `System Events` で打鍵、AppleScript で TextEdit の本文を読み戻す。出力行の契約は `SKILL.md` の表。

## チームレビューの結果（ateam review、run 7504bf9d936e）

3 人（claude、codex、grok）が各自レビューし、別の 1 人のレビューを検証した。静的レビューで、Mac では未実行。結論は「骨格は使えるが、このままでは合格にしない」。

### 反映済み

- TextEdit の既存文書を消しうる経路（高）。`verify.sh` は作成した文書の名前を保持し、その文書だけを読み・消し・閉じる。前面が自分の文書でなければ M1-M2 を打鍵せず FAIL にする。

### 未反映（高）

1. M3 に陽性対照が無い。`nomatch` が一件増えたこと、`matched` が増えないこと、`kill -0` で daemon 生存を判定にする。起動待ちの期限切れは FAIL。
2. シェル注入の項目が無い。`$(touch …)`、引用符、バッククォートを含む欄の文字で、実行されないことと完全一致を確かめる。
3. R2a/c/d/e/f が偽陽性（2026-10-31 の Mac 実行で確認）。判定が `invalid config` と exit 1 だけなので、旧ローダーが `action` 欠落で拒否しただけで PASS する。拒否理由を契約にし（`invalid config: empty trigger` / `unknown key action` / `unknown output replaceAll` / `empty output.shell` / `empty transform` / `unknown focus window`）、`bad()` で理由文字列を照合する。`verify.sh` に反映済み。実装側は同じ文言を出すこと。
4. `--probe` に期限が無い（doctor、M0、M4）。未知フラグの現バイナリでは daemon ループへ落ちて `--doctor` がハングし、孤児プロセスが残る（exit 142 で確認）。実装後も AX 待ちで固まれば検証全体が止まる。`cap 10` で包む。`verify.sh` に反映済み。

### 未反映（中）

- 改行。`printf 'A\n\n'` の例を足し、比較はバイト単位（`$(cat)` は末尾改行を全部落とす）。
- ルール選択。ルールごとに別ファイルへ書かせ、一つだけ動いたことを確かめる。不成立時は欄に `@@@` が残ること。
- 未知キー。`when` 内（`"apps"`）、`output` 内、トップレベル、旧キー `context`。
- 既定値。R2g にテキスト欄でない状況での発火と、無作用（欄 `hello` のまま）。
- 変換失敗時に `output.shell` が動かないこと。変換結果が `output.shell` の `$1` と環境変数へ届くこと。
- R6c。`tmux -f /dev/null` と受信用の `cat`、固有トークンを期限付きで待つ。
- 証拠ディレクトリ。`KP_EVIDENCE` を絶対パス化し、既存ディレクトリは拒否。
- 後片付け。daemon 停止の wait、`osascript` の期限、証拠消失を FAIL に数える。
- `--no-live` で M を飛ばした実行は「部分合格」と表示し、全体合格と分ける。
- R4b の補強。変換なしで欄が `hello` に戻ることを一項目足す（偽 Desktop の消去の健全性）。
- 前提に「入力ソースは ABC」を書く。日本語 IME では `keystroke` がローマ字変換される（未検証）。

### 未反映（低）

- 選択を扱わないことの確認。M1 の前に一部を選択しておく項目を一つ。
- AX のロールを証拠に残す。単一行の AXTextField の実機項目。
- `insert` / `clipboard` / `notify` の項目（最終状態で確かめる。ログ一行では不可）。
- M4 は記録だけにして合否に数えない。swift-format は品質の関門として分ける。
- `bad()` の `.exit` 保存、`--no-live` の SKIP を ID ごとに一行、`SKILL.md` の記述ずれ（doctor の Read-only、M1 の close）。

### 割れた論点と判断

| 論点 | 判断 |
| --- | --- |
| R4b は偽 Desktop で区別できない | 誤り。erase は末尾から消すので、キーが足されていなければ `HE` になり落ちる。偽 Desktop 自体の不具合用に補強項目を一つ足す |
| 選択を扱わないことの検証（高） | 低。Desktop に選択を読む口が無い |
| テキストエリアの確認 | 低。TextEdit 本文は AXTextArea なので M1 が証明する |
| Linux 対応の矛盾 | 矛盾ではない。設計の文言だけ直す |
| R2d/e は設計に無い | 設計に一行足して項目は残す |
| Input Monitoring を `--probe` で見るか | 未検証リスクとして Gotchas に書くだけ。M1 失敗時に切り分ける |

## 実機で確かめたこと（2026-10-31、macOS 26.6、使い捨ての Swift スクリプト）

スクリプトは `.claude/skills/verify-keypipe-rules/probes/`（`axprobe.swift` 前面の AX 要素の読み書き、`tap.swift` listen-only tap と Backspace の post、`imsel.swift` 入力ソースの切替）。`swiftc -O -o <出力> <ファイル>` で単体ビルドする。手順は「listen-only の CGEventTap を張る」「`System Events` で打鍵」「AX で前面の要素を読む・書く」「CGEvent で Backspace を post する」。

| 問い | 結果 |
| --- | --- |
| CGEventTap が `System Events` の合成打鍵を受けるか | 受ける。`hello@@@` の 8 打鍵すべてを keyDown で観測 |
| listen-only の tap に Input Monitoring が要るか | 要らなかった。未署名の CLI を端末（iTerm2）から起動し、`AXIsProcessTrusted` が true で tap も AX も動いた。TCC が端末に帰属しているのは推定 |
| 端末に要る許可 | Accessibility に加えて **Automation**（端末 → TextEdit、端末 → System Events）。初回はダイアログで osascript が止まり、約 60 秒で AppleEvent timeout（-1712）。`SKILL.md` の Doctor と下の手順 2 に足す |
| TextEdit の本文は `focus: textField` か | AXTextArea、`AXValue` 読み書き可。書き込み後の読み戻しも一致 |
| iTerm2 のプロンプトは AX 上テキスト欄か | **テキスト欄として見える**。AXTextArea で `AXValue` は画面全体（3,819 文字）、settable。設計の「テキスト欄ではない可能性」は逆で、欄の文字が画面全体になる方が問題。AXRole だけでは TextEdit と区別できない。`AXRoleDescription` が TextEdit では取れ、iTerm2 ではエラー（-25212）だったのが判別の候補（未検証） |
| CGEvent で post した Backspace は届くか | アプリ依存。**CotEditor では届く**（`abcdef` → `abc`）。AppleScript の `display dialog` の欄でも 4 回で 4 文字消えた。**TextEdit だけ無視する**。文字キー（`x`）は入るが Backspace・左矢印・前方削除は無視され、`System Events` の `key code 51` も espanso の post した Backspace も同じ。原因は未特定 |
| 自分が post した Backspace を自分の tap が拾うか | 拾う。`eventSourceUserData` で自分の事象だと識別できた |
| 日本語 IME | ATOK が有効だと `keystroke "hello@@@"` は `へっぉ＠` になる。変換中の文字には Backspace が効いた（`＠` 3 文字が espanso の 2 回で 1 文字に）。検証前に ABC へ切り替える（`TISSelectInputSource` で可） |
| espanso との共存 | 利用者の espanso に `@@` トリガーがあり、`@@@` を打つと espanso が Backspace 2 回と空白を post した。同じトリガー文字列を二つのツールが取り合う |
| TextEdit の予測入力 | 打鍵後に候補のポップオーバーが出て、出ている間は AppleScript の `get text` が止まる。Escape で閉じる。「osascript の期限」（中）は観測済みに格上げ |

設計への含意。

- 手順 3「Backspace で消す」は維持できるが、TextEdit では効かない。消去後に欄を読み戻し、末尾にトリガーが残っていれば `AXValue` からトリガーを取り除いて書き戻す予備経路を足す。
- `focus: textField` の既定ではあらゆるターミナルがテキスト欄として通り、プロンプトで `@@@` を打つと画面全体が入力になって `replaceInput` が走る。AXRole 以外の判別が要る。判別ができるまで、iTerm2 向けルールは `focus: any` にして欄の文字を使わない。
- 検証の前提に「入力ソース ABC」「espanso の `@@` トリガーを一時停止」「TextEdit の予測入力を閉じる」「端末への Automation 許可」を足す。

## 未検証のリスク

- ビルドし直すと Accessibility の許可が外れるか。
- Electron 系アプリが `AXValue` の書き込みを無視するか。
- TextEdit が合成 Backspace を無視する原因。ブラウザの欄でどうなるか。
- ターミナルをテキスト欄から外す判別（`AXRoleDescription` の有無が候補）。

## Mac での次の手順

1. 前提をそろえる。Xcode 15 か Swift 5.9 以降、`tmux`、TextEdit。入力ソースは ABC。TextEdit の未保存文書は閉じておく。
2. Accessibility と Automation（TextEdit、System Events）をターミナルに許可する（`System Events` の打鍵用）。Automation は初回の osascript でダイアログが出るので、そこで許可する。keypipe 本体への許可は実装後。
3. 実装前の基準を取る。今のコードは新しいフラグを持たないので R2 以降と M は FAIL するのが正しい。
   ```sh
   .claude/skills/verify-keypipe-rules/verify.sh --doctor
   .claude/skills/verify-keypipe-rules/verify.sh --no-live
   ```
4. 上の「未反映」を検証スキルへ反映してから実装に入る。高の二件は実装前に必須。
5. 実装後に全項目を実行し、`.verify-evidence/rules-*/results.tsv` を証拠として残す。
   ```sh
   .claude/skills/verify-keypipe-rules/verify.sh
   ```
