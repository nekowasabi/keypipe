# keypipe × voice-switch 実装可能性（再判定版 2026-11-01）

旧カタログ（`/workspace/keypipe-ideas/IMPLEMENTABILITY-2026-11-01.md`）は「action は shell/log だけ、CGEventTap 未配線」という古い前提で判定していた。本書は 2026-11-01 の `main` のコードを読み直して判定し直したもの。ateam idea（run 1f8bd0cc450a）の合意を反映している。

## 0. 読み方（Claude Code 向け）

- 判定は4区分。**可能** = 今の設定だけで書ける。**機能追加** = §2 の M 番号を実装すれば書ける。**不明** = 両リポ外の仕様（herdr / agmsg / Muse など）か、アプリの AX 挙動が未検証。**不可** = 確実な手段が無い。
- 経路は3つ。**K** = 打鍵（常駐デーモン、MacKeyTap → Engine）。**Z** = 端末の zsh widget（`keypipe --line`）。**V** = 音声（voice-switch の `macOS.actions[].command` → `keypipe --line <trigger>`）。
- 「shell 代用」は、transform や output.shell の中で条件を判定するという意味。ネイティブの `when` 条件ではない。発火と欄の読取が済んだ後に判定するので、除外（安全）の用途には使えない。
- **E** の印 = Electron / Web の入力欄。AXValue の書込みが効くかは未検証。効かなければ Engine は `ignored` で失敗する。`onFail.output: {"shell": "pbcopy"}` と通知で結果を失わないようにする。
- 振り分けの規則（チーム合意）: transform・onFail・when が要る語だけ keypipe を通す。配送だけの語は voice-switch の url / webhook / command から直接送る。

## 1. 現行で出荷済みの部品（旧カタログの「不足」から外したもの）

コードから確認した事実:

- `Config.swift`: rule のキーは `trigger | hotkey | when{app[], focus} | transform | output | onFail{transform, output}`。output は `none | replaceInput | notify | {shell, background}`。トップレベルは `shellTimeout` と `backgroundTimeout`。**未知のキーはロード時に拒否する**（ルーティング表などを config に同居させられない）。
- `Engine.swift`: IME 変換中は発火しない（:143）。トリガーを消す。`focus: textField` なら AX で欄を読む。transform が非0・timeout・空出力なら配送しない。
- `Shell.swift:66-68`: 子 shell は親の環境をそのまま継承する（`VOICE_SWITCH_APP` も届く）。入力は stdin / `$1` / `KEYPIPE_INPUT`。cwd は変えない（zsh widget 経由なら端末のカレントディレクトリになる）。
- `main.swift`: `--probe` は前面アプリ・focus 種別・欄のテキストを JSON で出す。`--triggers`。`--line <trigger> [--app]` は stdin を仮想欄として実行し、新しい行を stdout に出す。exit 0 はルールが一致したことを意味するだけで、配送の成功ではない。
- `MacDesktop.swift:18` / `Engine.swift:139`: 前面アプリが pty を持つ（端末）なら、**hotkey も含めて全ルールが発火しない**。
- secure 欄の判定は keypipe 側に無い（`secure` で grep しても該当なし）。voice-switch の `pasteDictation` 側には除外がある。
- voice-switch: action は `url | webhook | command` を持つ。command には本文が stdin で渡り、`VOICE_SWITCH_APP` が入る。stdout は捨てられる（`Platform.swift:69-93`）。ウェイク語のあとに何も言わないと取り消す（`MacApp.swift:1204`）。

旧カタログの不足45件のうち、次の13件は出荷済み: mac-keytap, ime-guard, trigger-erase, context-match(when.app 配列), when.focus, hotkey-trigger, capture-field, transform-pipe, sink-replaceInput, sink-notify, vs-shell-action, capture-buffer(--line), modifier-variant（`ctrl+k` と `ctrl+K` を別ルールで書ける）。sink-clipboard / sink-fixedText / sink-append / field-length / dry-run / rule-chain は transform と output.shell で代用できる（ネイティブの機能は不要）。

## 2. 不足機能（案の多い順）

| ID | 側 | 内容 | 解放する案 |
|---|---|---|---|
| M1 | voice-switch（＋keypipe の契約） | command の stdout を捨てず、既存の `pasteDictation`（`MacApp.swift:348-393`、対象の前面化・clipboard の退避と復帰・secure 除外付き）で現在位置に**挿入**する。`MacApp.swift:538` の `.command` 分岐に足す。**前提の契約**: keypipe `--line` は transform や output が失敗しても元の行を stdout に返し、exit 0 になる（`main.swift:92-94`）。成功時だけ本文を出すフラグ（例 `--result-only`: 失敗なら exit 3 で stdout は空）を keypipe に足す。これをしないと、失敗時に原文が貼られる | D1-D7, D17, D22, A28, N1, N9, N12 ほか 約15 |
| M3 | voice-switch | 本文なしで action を実行するフラグ（例 `requireBody: false`）。今は「けいご」だけ言うと取り消される | D1-D7, D10, D13, D15, D18, D23, D28 |
| M2 | keypipe | 実デスクトップへの外部呼び出し。`keypipe --fire <trigger>` を MacDesktop に対して実行する（前面欄の AX 読取と書込み、トリガー消去なし）。声から**既存の欄全体を書き換える**のに要る。M3 と組で使う | D1-D7（既存欄の書換え）, A28 |
| M18 | keypipe | 端末前面でも `focus: any` のルールは発火させる（入力は空なので、ペイン全体が漏れる危険は無い）。今は `Engine.swift:139` が全ルールを止める | A19, A23, A25, A31, C3（iTerm などが前面のとき） |
| M4 | keypipe | `when.url`。前面ブラウザのタブ URL を AppleScript で取って glob 照合する（Automation 許可が要る）。欄を読む前に効くこと | A5, B20-B25, C9 |
| M5 | keypipe | 選択範囲。`kAXSelectedText` を読み、`kAXSelectedTextRange` を置換する。失敗時は Cmd+C / Cmd+V。hotkey での発火が前提 | A8, C15 |
| M6 | keypipe | `when.app` の除外（`not`）とトップレベルの `denyApps`。欄を読む前に効くこと | C4 |
| M7 | keypipe | secure 欄のガード（`AXSubrole == AXSecureTextField` なら読まない・書かない）。既定で有効 | C14（全ルールの安全弁） |
| M8 | keypipe | `when.windowTitle`（AXTitle を正規表現で照合） | C10, B5 |
| M9 | keypipe | `when.ext`（AXDocument から拡張子） | C11 |
| M10 | keypipe | `when.field`（AXPlaceholderValue / AXDescription / AXIdentifier） | C12, C31 |
| M11 | keypipe | `when.caret`（`kAXSelectedTextRange.location` が行頭か） | C16 |
| M12 | keypipe | hotkey の keyUp（`onDown` / `onUp`）。押して話す方式用 | A30, D22 |
| M13 | keypipe | アイドルイベント（最後の keyDown から N ms 後に発火） | C17 |
| M14 | keypipe | `when.inputSource`（TISCopyCurrentKeyboardInputSource） | C18 |
| M15 | keypipe | トリガー履歴（`when.after`、連打回数 `KEYPIPE_REPEAT`） | C19, C20 |
| M16 | keypipe | 外部イベント源（ファイル監視やソケット通知でルールを起動） | A10, A17, C29 |
| M17 | keypipe | typeText 出力（CGEvent で文字を打つ）。端末は zsh widget があるので要らない。Simulator やキャンバス描画の欄向け | B8, B28 |
| M19 | keypipe | config の再読込（SIGHUP かファイル監視） | N14 |

両リポの外にある未確認の依存: herdr CLI（`hc ...` の形は未検証）、Mac 上の agmsg、Muse CLI、choose-gui、Grok Bot の Mac 用 prompt link（Windows では空欄になった報告あり）。

推奨順: **M1（＋成功時だけ本文を返す契約）→ M3 → M7 → M18 → M4 → M2 → M5 → 残り**。

## 3. 126件の個別判定

### A 連携・用途
| ID | 判定 | 経路 | 方法 / 不足 / 注記 |
|---|---|---|---|
| A1 丁寧語化 | 可能 | K | transform `claude -p '丁寧語に。結果だけ'`、replaceInput、focus textField。E |
| A2 英訳＋原文退避 | 可能 | K | transform `printf %s "$1" \| pbcopy; claude -p 'Translate...'`（`/bin/sh` なので `>(...)` は使えない）。E |
| A3 箇条書き⇄文章 | 可能 | K | `@@li` と `@@bun` の2ルール。旧案の `@@pr` は A5 と衝突する |
| A4 コミット文 | 可能 | Z | zsh widget 経由なら cwd は端末のディレクトリ。transform `printf '%s' "$1"; git diff --staged \| claude -p ...`。打鍵（K）は端末前面だと発火しない |
| A5 PR 本文 | 可能 | K | transform 内で `osascript` からタブ URL を取り、`/pull/N` か compare 画面かで `gh pr diff` と `git diff main...HEAD` を分ける。ブラウザ・サイトで絞るには M4。E |
| A6 textlint | 可能 | K | `textlint --stdin --stdin-filename x.md --fix --format fixed-result`。この版の出力形式は要確認 |
| A7 140字＋字数通知 | 可能 | K | transform の中で `osascript` で字数を通知してから結果を出す（output は1つしか持てない） |
| A8 選択範囲だけ | 機能追加 | K | M5 |
| A9 欄→Grok Bot | 可能（欄クリアは除く） | K | output.shell `open "grokbot://...&text=$(printf %s "$1" \| jq -sRr @uri)"`。欄を空にするのは不可（空出力は失敗扱い）。Mac の prompt link の挙動は未検証 |
| A10 Grok Bot 返答通知 | 不明 | — | 返答を受け取る経路が無い。M16 と受け口の仕様が要る |
| A11 herdr へ prompt | 不明 | K/V | herdr CLI が未検証。tmux 版（`tmux send-keys -l`）なら可能 |
| A12 宛先ピッカー | 不明 | K | herdr の一覧 CLI ＋ choose-gui。tmux 版なら `tmux list-panes -a -F ... \| choose` で可能 |
| A13 idle へ振分け | 不明 | K | herdr の状態取得が未検証 |
| A14 Codex レビュー→通知 | 可能 | K/V | output `{"shell": "codex exec ... \| claude -p '3行' ; osascript ...", "background": true}`。herdr 版は不明 |
| A15 Muse→CotEditor | 不明 | K | Muse の CLI 名が未確認。CotEditor への出力自体は可能 |
| A16 2エージェント比較 | 可能 | K/V | `claude -p` と `codex exec` を直接呼び、background で CotEditor に出す。herdr 版は不明 |
| A17 blocked へ返答 | 不明 | K | herdr の blocked 検知（＋M16） |
| A18 dev-handoff→agmsg | 不明 | K/V | Mac に agmsg があるか、Grok Bot がそのチームにいるかが未確認。webhook 宛てなら可能 |
| A19 全停止 | 可能（tmux） | K/V | `tmux list-panes -a` を回して `C-c`。端末前面では発火しない（M18）。herdr 版は不明 |
| A20 エラー原因調査 | 可能 | K/V | `claude -p` → `/tmp/why.md` → `open -a CotEditor` |
| A21 tmux 送信 | 可能 | K/Z/V | output.shell `tmux send-keys -t work:1 -l -- "$1"` |
| A22 自然文→コマンド | 可能 | Z | zsh widget で transform を通し、replaceInput。実行はしない |
| A23 ペイン要約通知 | 可能 | K | `focus: any` の hotkey、transform `tmux capture-pane -p \| tail -200 \| claude -p`、notify。端末前面では M18 |
| A24 herdr ダッシュボード | 不明 | K | herdr の一覧 JSON が未検証 |
| A25 スクロールバック→CotEditor | 可能 | K | A23 と同じ（M18） |
| A26 SSH 先へ | 可能（ssh+tmux） | K/V | `ssh vps tmux send-keys ...`。herdr のリモート送信は不明 |
| A27 vs 宛先を keypipe に統一 | 可能 | V | command `keypipe --config ~/.config/keypipe/config.json --line <trigger> ${VOICE_SWITCH_APP:+--app "$VOICE_SWITCH_APP"}`。output.shell 系はそのまま動く。replaceInput 系は M1 |
| A28 口述後に自動整形 | 機能追加 | V | 「口述して整形し挿入」は M1。「貼った後の欄を整形」は M2＋M3。旧案の「末尾に @@k を付けて貼る」は Cmd+V なので tap に文字が届かず動かない |
| A29 宛先名＋本文 | 可能 | V | voice-switch の action の `wakeWords` を宛先ごとに分ける（ネイティブ）。transform で先頭語を切っても書ける |
| A30 押して話す | 機能追加 | K | M12 |
| A31 結果を say | 可能 | K/V | output.shell `say`。端末前面の hotkey は M18 |
| A32 ルーティング表 | 可能 | — | config に同居させず（未知キーは拒否）、別ファイル＋生成スクリプトで両方の config を書き出す |

### B アプリ別
| ID | 判定 | 経路 | 方法 / 注記 |
|---|---|---|---|
| B1 iTerm2 | 可能 | Z | zsh widget のみ。nvim / less / REPL の中では不可。デーモンは端末では動かない |
| B2 Terminal | 可能 | Z | 同上 |
| B3 Ghostty | 可能 | Z | 同上 |
| B4 WezTerm | 可能 | Z | 同上 |
| B5 VS Code SCM 欄 | 不明 | K | Monaco 欄の AX 読み書きと、統合ターミナル（pty を持つのは子プロセス）で端末判定が効くかが未検証。リポジトリの特定に M8 |
| B6 Cursor 定型 | 可能 | K | transform `printf '定型文'`（入力を無視）＋ replaceInput。E |
| B7 Xcode | 可能 | K | when.app `com.apple.dt.Xcode` |
| B8 Simulator | 不明 | K | iOS の欄は macOS の AX に出ない。M17 か Cmd+V の実機確認 |
| B9 CotEditor 出力先 | 可能 | — | `open -a CotEditor <file>` |
| B10 Obsidian 追記 | 可能 | K | transform `printf '%s\n\n' "$1"; printf %s "$1" \| claude -p '3行要約'` → replaceInput（追記を置換で代用）。E |
| B11 Bear | 可能 | K | when.app `net.shinyfrog.bear` |
| B12 Notes | 可能 | K | AX 書込みは未検証。onFail.output で pbcopy |
| B13 Things | 可能 | K | `things:///add?titles=` の改行区切りの書式は要確認 |
| B14 Craft | 不明 | K | bundle id と本文欄の AX が未確認 |
| B15 Notion | 不明 | K | ブロック型の contenteditable。replaceInput は ignored になりやすい → onFail.output で Cmd+V 経由 |
| B16 Slack | 可能 | K | E |
| B17 Discord | 可能 | K | E |
| B18 LINE | 可能 | K | bundle id は `osascript -e 'id of app "LINE"'` で確認 |
| B19 Mail | 不明 | K | WebKit の本文欄の AX 書込み |
| B20 Chrome | 可能（アプリ単位） | K | サイトの区別は M4。E |
| B21 Safari | 可能（アプリ単位） | K | 同上 |
| B22 Arc | 可能（アプリ単位） | K | 同上。Arc の AppleScript で URL が取れるかは要確認 |
| B23 GitHub | 可能 | K | A5 と同じ（URL は transform 内で取得） |
| B24 X | 不明 | K | contenteditable の AX 書込み |
| B25 ChatGPT/Claude/Grok Web | 不明 | K | 同上 |
| B26 Raycast/Alfred | 不明 | K | 合成入力や AX 書込みでパネルが閉じる恐れ |
| B27 Finder リネーム | 不明 | K | 一時欄なので、確定・取消のタイミング |
| B28 Sheets/Numbers セル | 不明 | K | キャンバス描画。M17 |
| B29 TablePlus | 可能 | K | bundle id は要確認 |
| B30 Postman JSON | 可能 | K | transform `jq .`。E（Monaco） |
| B31 herdr | 不明 | — | CLI が未検証 |
| B32 Grok Bot | 可能 | K/V | URL か webhook。Mac の prompt link は未検証 |

### C 条件
| ID | 判定 | 方法 / 不足 |
|---|---|---|
| C1 app 配列 | 可能 | `when.app` は配列（出荷済み） |
| C2 focus textField | 可能 | 出荷済み |
| C3 any＋hotkey | 可能 | 出荷済み。端末前面は M18 |
| C4 除外リスト | 機能追加 | M6（shell 代用は欄を読んだ後なので安全用途に不可） |
| C5 時刻 | 可能（shell 代用） | `date +%H` |
| C6 git cwd | 可能（shell 代用） | Z なら cwd 継承、K は `tmux display -p '#{pane_current_path}'` |
| C7 herdr 状態 | 不明 | herdr CLI |
| C8 tmux ペインタイトル | 可能（shell 代用） | `tmux display -p '#{pane_title}'` |
| C9 URL | 機能追加 | M4 |
| C10 ウィンドウタイトル | 機能追加 | M8（shell 代用は System Events で可能） |
| C11 拡張子 | 機能追加 | M9 |
| C12 placeholder | 機能追加 | M10 |
| C13 欄が空か | 可能（shell 代用） | transform で `[ -z "$1" ]` 分岐 |
| C14 secure 欄 | 機能追加 | M7。Secure Input 中は tap にキーが届かないが、AXSecureTextField 単体のガードは無い |
| C15 選択あり/なし | 機能追加 | M5 |
| C16 キャレット行頭 | 機能追加 | M11 |
| C17 アイドル | 機能追加 | M13 |
| C18 入力ソース | 機能追加 | M14（IME の composing 中は今も不発。入力ソースによる条件は別物） |
| C19 直前トリガー連鎖 | 可能（代用）/ 機能追加 | 整形→英訳は transform 内でパイプすれば今書ける。時間窓の連鎖は M15 |
| C20 連打回数 | 機能追加 | M15 |
| C21 修飾キー違い | 可能 | `"ctrl+k"` と `"ctrl+K"` を別ルールにする（shift はキーの一部） |
| C22 フルスクリーン | 可能（shell 代用） | System Events で AXFullScreen を取得 |
| C23 画面共有中 | 不可 | 公開 API が無い。代替: 会議アプリが起動中なら通知本文を伏せる（shell 代用） |
| C24 ディスプレイ構成 | 可能（shell 代用） | `system_profiler SPDisplaysDataType` |
| C25 ネットワーク | 可能（shell 代用） | `ping -c1 -t1` |
| C26 電源 | 可能（shell 代用） | `pmset -g batt` |
| C27 集中モード | 不明 | 公開 API が無い。ショートカットの自動化で状態をファイルに書く回避策 |
| C28 clipboard 種別 | 可能（shell 代用） | `pbpaste` で判定 |
| C29 herdr blocked イベント | 不明 | herdr のイベント仕様＋M16 |
| C30 音声由来 | 可能（shell 代用） | voice-switch が設定した `VOICE_SWITCH_APP` が子 shell に継承される。`[ -n "${VOICE_SWITCH_APP+x}" ]`（空でも定義済みなので `+x`） |
| C31 アプリ内ペイン識別 | 不明 | M10＋Slack の AX ツリーの安定性 |
| C32 ドライラン | 可能（代用） | 同じ transform で output を notify にした確認用トリガーを別に置く。フラグでの差し替えはネイティブには無い |

### D voice-switch → keypipe
共通: V 経路は「ウェイク語＋本文」を発話し、本文が `--line` の入力になる（`focus: textField` 必須）。output.shell / notify / background は動く。replaceInput の結果は M1 が入るまで欄に入らない。

| ID | 判定 | 方法 / 不足 |
|---|---|---|
| D1 けいご | 機能追加 | 口述文を丁寧語にして挿入 = M1。既存の欄を書き換える = M2＋M3 |
| D2 えいごに | 機能追加 | D1 と同じ |
| D3 コミットかけて | 機能追加 | M1（端末の行へ Cmd+V）。cwd は launchd 側なので `tmux display -p '#{pane_current_path}'` で取る |
| D4 ピーアール書いて | 機能追加 | M1（欄の内容は不要なので挿入で足りる）＋M3（本文なし） |
| D5 エックス用に短く | 機能追加 | D1 と同じ |
| D6 リントして | 機能追加 | D1 と同じ |
| D7 箇条書きに/文章に | 機能追加 | D1 と同じ。語ごとに action を分ける |
| D8 グロック→Grok Bot | 可能 | voice-switch 直送（url / webhook）。keypipe は不要。Mac 実機は未検証 |
| D9 クロードへ | 可能（tmux） | voice-switch のペイン振分け、または command→`--line`→`tmux send-keys`。herdr 版は不明 |
| D10 コーデックスへレビュー | 可能 | 本文にレビュー観点を言う → background で `codex exec` → 通知。本文なしは M3 |
| D11 ミューズで広げて | 不明 | Muse CLI |
| D12 空いてるエージェントに | 不明 | herdr |
| D13 宛先選んで | 不明 | herdr＋M3 |
| D14 ブロック中に答えて | 不明 | herdr |
| D15 全部止めて | 機能追加 | M3（本文が無いと取り消される）。回避策は「全部止めて、今すぐ」と本文を付けて言う |
| D16 ティーマックスいちへ | 可能 | voice-switch の既存のペイン振分け（ウィンドウ名を発話しやすい語にする） |
| D17 シェルにして | 機能追加 | M1（端末へ挿入。Enter は送らない） |
| D18 ペイン要約 | 機能追加 | M3。回避策は本文を付けて言う |
| D19 エージェント状況 | 不明 | herdr |
| D20 なんで | 可能 | 本文＝エラーの説明 → `claude -p` → CotEditor。「なんで」は日常語で誤発火しやすいので語を長くする |
| D21 デブハンドオフ | 不明 | agmsg on Mac。webhook 宛てなら可能 |
| D22 PTT 離して整形 | 機能追加 | M12＋M1 |
| D23 読み上げて | 機能追加 | M3。各ルールが結果を `/tmp/kp-last.txt` に tee しておく |
| D24 同じ質問を二つへ | 可能 | `claude -p` と `codex exec` を直接（A16） |
| D25 リモートのクロードへ | 可能（ssh+tmux） | herdr 版は不明 |
| D26 語彙↔rule の単一表 | 可能 | 表は別ファイル。生成スクリプトが keypipe の rules と voice-switch の actions を書き出し、`keypipe --triggers` で突合する |
| D27 ドライラン | 可能（代用） | 「ドライラン コーデックスへ」を別 action にし、同じ transform＋output notify のトリガーへ |
| D28 クリップボードでけいご | 可能 | transform `pbpaste \| claude -p ...`、output.shell `pbcopy`。本文に何か一言必要（なしは M3） |
| D29 けいごしてグローブボットへ | 可能（代用） | transform を `claude -p ...` の1段にし、output.shell で Grok Bot へ（ネイティブの連鎖は不要） |
| D30 いつもの | 可能 | 各配送の shell が宛先をファイルに保存し、「いつもの」はそれを読んで送る。宛先名を必ず通知する |

## 4. 新案30（既存126件と重複しないもの）

採点は 新規性/実現性/インパクト/リスク（各1〜5、リスクは低いほど良い）。N1〜N8 は ateam idea の席から、N9〜N30 は本書で追加した。

| ID | 案 | 経路 | 必要機能 | 判定 | 採点 |
|---|---|---|---|---|---|
| N1 | 送信前のローカル伏字ゲート: 既知の秘密形式を伏字にし、伏字処理が非0か空なら配送しない（onFail.transform で原文を返す設定はしない）。鍵盤と声で同じルールを共有する | K/V | なし（伏字スクリプト） | 可能 | 4/5/3/3 |
| N2 | 配送失敗だけ保留→文字トリガーで明示的に再送: `onFail.output` が `KEYPIPE_FAILURE` 付きで保留ファイルへ。timeout は「結果不明」として自動再送しない | K/V | なし（保留・排他・再送スクリプト） | 可能 | 3/4/3/3 |
| N3 | 口述を整形して現在位置に挿入（欄全体は読まない） | V | M1 | 機能追加 | 3/4/5/3 |
| N4 | 声で `keypipe --probe` を先に呼び、欄が空なら挿入、空でなければ通知に落とす | V | なし（M1 があれば挿入まで） | 可能 | 4/4/3/2 |
| N5 | 1ルールで鍵盤と声を分岐: transform で `${VOICE_SWITCH_APP+x}` を見て、声なら短く、鍵盤なら欄全体を整形 | K/V | なし | 可能 | 4/5/4/1 |
| N6 | voice-switch の wakeWords と `keypipe --triggers` を突き合わせ、片方にしか無い語やトリガーを検出する | — | なし（スクリプト） | 可能 | 3/5/2/1 |
| N7 | 「言い直し」: 直前の `--line` 入力を保存しておき、次の発話で上書きして同じ出力へ送り直す | V | なし | 可能 | 3/4/3/2 |
| N8 | 長い LLM 整形は `background: true` にして voice-switch の command をすぐ返し、結果は通知で受ける | V | なし | 可能 | 3/5/3/2 |
| N9 | 「さっきの」: voice-switch の journal（`~/Library/Application Support/voice-switch/journal/*.jsonl`）から最新の発話を読み、打鍵トリガーで今の欄の末尾に足す | K | なし | 可能 | 4/4/4/2 |
| N10 | 直近5件の発話を hotkey で choose-gui に出し、選んだものを欄に追記する（言い間違えた宛先からの救出にも使える） | K | なし（choose-gui） | 可能 | 4/4/3/2 |
| N11 | 「日報」: 当日の journal を `claude -p` で要約し、CotEditor か Obsidian の日次ファイルへ追記する | V | なし | 可能 | 3/5/3/2 |
| N12 | アプリに合わせた1語整形「ととのえて」: `VOICE_SWITCH_APP` / `KEYPIPE_APP` で transform のプロンプトを切り替える（Slack＝敬語、iTerm＝コマンド、Xcode＝コード） | K/V | なし（挿入は M1） | 可能（挿入は機能追加） | 4/4/4/2 |
| N13 | 口述のコード化: 「かっこ」「イコール」など話し言葉の記号をコードに直して挿入する | V | M1 | 機能追加 | 4/3/3/3 |
| N14 | 声でルール追加: 「ルール追加、@@foo は…」→ `claude -p` で JSON を生成 → `jq` で検証 → `keypipe --triggers` でロードを確認 → config に書く | V | M19（再読込。無ければデーモン再起動） | 機能追加 | 4/3/3/4 |
| N15 | config 保存時の自動検証: ファイル監視で `keypipe --config X --triggers` を走らせ、`invalid config` なら通知する（未知キーの拒否で起動不能になる事故を防ぐ） | — | なし（launchd WatchPaths） | 可能 | 2/5/3/1 |
| N16 | 「さっきの失敗」: `~/.local/state/keypipe/jobs.log` の末尾を要約して読み上げる | V | なし（本文なしは M3） | 可能 | 3/5/2/1 |
| N17 | 声でメール下書き: 口述から宛先・件名・本文を抽出し、`osascript` で Mail の下書きを作る（送信はしない） | V | なし | 可能 | 3/4/3/3 |
| N18 | 声でリマインダー: 「リマインド、明日10時に〇〇」→ 日時を解析 → Reminders.app に登録する | V | なし | 可能 | 2/4/3/2 |
| N19 | 声で予定登録: 口述からカレンダーの予定を作る（Calendar.app の osascript か gcalcli） | V | なし | 可能 | 2/4/3/3 |
| N20 | 誤認識辞書: 「下ね→舌根」のような置換表を sed で transform の先頭に通し、どのルールでも共通に使う | K/V | なし | 可能 | 3/5/3/1 |
| N21 | 声でブランチ作成: 「ブランチ、ログイン修正」→ 英語スラッグにして `tmux send-keys` で `git switch -c <slug>` を入れる（Enter は送らない） | V | なし | 可能 | 3/5/3/2 |
| N22 | 声でペイン移動: 「ペインへ、テスト」→ タイトルが部分一致する tmux ペインを `select-pane` する（既存の振分けは文字を送るだけで、フォーカスは移さない） | V | なし | 可能 | 3/5/3/1 |
| N23 | 取り消し: 各 transform が書き換え前の入力を保存しておき、`@@undo`（replaceInput）で戻す | K | なし | 可能 | 3/4/4/2 |
| N24 | 長文はモデルを切り替える: transform の中で `${#1}` を見て、長ければ速いモデル、短ければ高精度のモデル（`shellTimeout` 超過を避ける） | K/V | なし | 可能 | 2/5/3/1 |
| N25 | 「この欄に何を書けばいい？」: `--probe` の app と fieldText を `claude -p` に渡し、提案を通知する（欄は書き換えない） | V | なし（本文なしは M3） | 可能 | 4/4/3/2 |
| N26 | 欄を読み上げて耳で校正: hotkey で欄全体を `say` する（output none） | K | なし | 可能 | 3/5/2/1 |
| N27 | 予約送信: 「あとで送って、10分後」→ `background` の shell が待ってから配送し、宛先と時刻を通知する（`backgroundTimeout` を延ばす必要あり） | V | なし | 可能 | 3/4/3/3 |
| N28 | 発火回数の集計: 各ルールの shell が `rule,ts` を1行ずつ記録し、週次で使わないルールと誤爆の多いルールを報告する | — | なし（デーモンの transcript の保存先は未確認なので自前で記録する） | 不明（デーモンのログ取得）/ 可能（自前記録） | 2/4/2/1 |
| N29 | 声の宛先を前面アプリで自動決定: 1語「おくって」で、iTerm が前面なら tmux、Slack なら挿入、それ以外は Grok Bot | V | なし（挿入は M1） | 可能（挿入は機能追加） | 4/4/4/3 |
| N30 | 音声→keypipe の配送結果を HUD に返す: `--line` の exit 2（ルール無し）と exit 0 を voice-switch のログから通知に出す（今は `command exited 2` がログにしか出ない） | V | voice-switch の小改修（command の終了コードを通知） | 機能追加 | 2/5/3/1 |

## 5. 集計と残る論点

- 内訳（126件）: 可能 70（「shell 代用」「代用」「アプリ単位」「tmux 版」などの条件付きを含む）/ 機能追加 26 / 不明 29 / 不可 1（C23）。旧カタログでは possible-mvp 15 / after-caps 75 / uncertain 35 / blocked 1 だった。
- 未合意: N1 / N2 は「シェルだけでもできる」として連携の価値を低く見る意見がある（grok 席）。採用するのは鍵盤と声で設定を共有する場合に限る。
- 未検証: M1 の pasteDictation が発話直後に idle≥1秒の条件を満たすか。Electron 欄の AX 書込み。herdr / agmsg / Muse の仕様。Grok Bot の Mac 用 prompt link。
