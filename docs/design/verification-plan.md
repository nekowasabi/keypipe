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

レビューで決めた既定（`context-rules.md` へ未反映）。

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

## 未検証のリスク

- CGEventTap が `System Events` の合成打鍵を受け取るか。
- listen-only の CGEventTap に Input Monitoring の許可が要るか。端末から起動したときの TCC の帰属先。
- ビルドし直すと Accessibility の許可が外れるか。
- iTerm2 のプロンプトが AX 上テキスト欄か。
- Electron 系アプリが `AXValue` の書き込みを無視するか。
- 日本語 IME 変換中の発火と Backspace の数。

## Mac での次の手順

1. 前提をそろえる。Xcode 15 か Swift 5.9 以降、`tmux`、TextEdit。入力ソースは ABC。TextEdit の未保存文書は閉じておく。
2. Accessibility をターミナルに許可する（`System Events` の打鍵用）。keypipe 本体への許可は実装後。
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
