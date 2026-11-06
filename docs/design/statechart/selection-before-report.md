# SelectionCapture

TLC reached 352 states and 420 steps. The chart draws 31 states and 41 arrows.
The view hides 84 steps, so the chart does not draw them.

## OldClipboardRestored breaks
The shortest path has 4 steps:
0. ホットキーが届いた [Chrome]
1. ロックを取り、退避して空にする: 退避して空にした [Chrome]
2. Cmd+C [失敗]: Cmd+C が失敗した
3. 元のクリップボードを戻す: 元のクリップボードを戻した（Cmd+C 失敗） [画像などが消えた]
4. exit 1: 失敗を報告した [画像などが消えた]

## BrowserUrlAttached breaks
The shortest path has 5 steps:
0. ホットキーが届いた [Chrome]
1. ロックを取り、退避して空にする: 退避して空にした [Chrome]
2. Cmd+C: コピーされた: テキスト+HTML+source-url [ブラウザ]
3. コピーを読む: 読み取った: ページ URL なし
4. 元のクリップボードを戻す: 戻した: ページ URL なし
5. プロンプトを出す: プロンプトを出した: ページ URL なし

## HrefNeverDropped breaks
The shortest path has 5 steps:
0. ホットキーが届いた [Chrome]
1. ロックを取り、退避して空にする: 退避して空にした [Chrome]
2. Cmd+C: コピーされた: テキスト+HTML+source-url [ブラウザ]
3. コピーを読む: 読み取った: リンク先を落とした・ページ URL なし
4. 元のクリップボードを戻す: 戻した: リンク先を落とした・ページ URL なし
5. プロンプトを出す: プロンプトを出した: リンク先を落とした・ページ URL なし

## Rules that hold
PageUrlOnlyFromBrowser, FailedCopyNotSent, NoDeadlock
