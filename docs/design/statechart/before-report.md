# KeypipeFire

TLC reached 65 states and 88 steps. The chart draws 31 states and 29 arrows.
The view hides 33 steps, so the chart does not draw them.

## UnreadableNeverFallsThrough breaks
The shortest path has 2 steps:
0. トリガーが届いた [ブラウザ]
1. ゲートを通す: ゲートを通った [ブラウザ]
2. URL を読む [読めない → 次のルールへ]: 汎用ルールを選んだ [URL が読めないまま]

## NoReadInSecureField breaks
The shortest path has 3 steps:
0. トリガーが届いた [パスワード欄]
1. ゲートを通す: ゲートを通った [パスワード欄]
2. 汎用ルールが一致: 汎用ルールを選んだ [パスワード欄]
3. 欄を読み、トリガーを消す: 欄を読んでトリガーを消した（汎用ルール） [パスワード欄]

## StartedMeansSpawned breaks
The shortest path has 4 steps:
0. トリガーが届いた [編集欄]
1. ゲートを通す: ゲートを通った [編集欄]
2. 汎用ルールが一致: 汎用ルールを選んだ
3. 欄を読み、トリガーを消す: 欄を読んでトリガーを消した（汎用ルール）
4. 出力 background [起動に失敗]: 裏で起動したと報告、実際は起動していない

## NoFakeTypeText breaks
The shortest path has 4 steps:
0. トリガーが届いた [編集欄]
1. ゲートを通す: ゲートを通った [編集欄]
2. 汎用ルールが一致: 汎用ルールを選んだ
3. 欄を読み、トリガーを消す: 欄を読んでトリガーを消した（汎用ルール）
4. 出力 typeText [zsh/音声]: 打ち込んだと報告（zsh/音声: 打ち込む先が無い）

## Rules that hold
NoDeadlock
