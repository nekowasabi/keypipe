# keypipe

[English](README.md) | 日本語

keypipe はキーシーケンスをアクションにマッピングする Mac バックグラウンドデーモンで、
Espanso に似ています。`@@@` のようなトリガーを入力すると、keypipe は設定された
アクション（シェルコマンドまたはログ行）を実行します。メニューバー UI は意図的に
ありません。ステータスアイテムも設定ウィンドウもありません。設定は 1 つの JSON
ファイルに記述します。

## 必要条件

- macOS 13 以降、Xcode 15 または Swift 5.9 ツールチェーン。
- Linux ビルドでは `--feed-stdin` と `--smoke-feed` 経由でマッチャー／アクションの
  パス全体を実行します。macOS のキー取得（key tap）はドキュメント化された
  フックポイントであり、この MVP では未配線です。

## ビルド

```sh
swift build
```

## 実行

```sh
swift run keypipe --config ./config.example.json
# or
.build/debug/keypipe --config /path/to/keypipe.json
```

起動時にデーモンはルール数と設定パスとともに `keypipe started` を出力します。
SIGINT（Ctrl-C）または SIGTERM（`kill -TERM`）まで動作し続けます。

Linux および開発環境ではキー取得が無いため、入力は明示的に渡します。

```sh
# Feed one string through the matcher and run any matched actions.
.build/debug/keypipe --config ./config.example.json --smoke-feed '@@@'
# Stream stdin line by line through the matcher until EOF.
echo '@@@' | .build/debug/keypipe --config ./config.example.json --feed-stdin
```

マッチするとデーモンは `keypipe matched <trigger>` を出力し、ルールの
アクションを実行し、`keypipe action exit <status>` を出力して、マッチャーを
リセットするため同じトリガーが再び発火できます。`--smoke-feed` は少なくとも
1 件ヒットすると終了コード 0、マッチ無しでは 2 で終了します。

## 設定

1 つの JSON ファイル（MVP では `"json"` 形式のみ受け付けます。TOML と YAML は
対象外です）。パスは `--config` で渡し、既定値は `./config.example.json` です。
まず `config.example.json` をコピーして開始してください。

```json
{
  "rules": [
    {
      "trigger": "@@@",
      "action": { "type": "shell", "command": "echo keypipe-triggered" },
      "context": { "appBundleId": null, "processName": null }
    }
  ],
  "logPath": null
}
```

- `trigger` は直近のキー入力のサフィックスとしてマッチする空でない文字列で、
  最大 64 文字（`triggerMaxBuffer`）です。より長いトリガーはバッファに収まらない
  ため読み込み時に拒否されます。複数のルールが同じバッファにマッチした場合は
  最も長いトリガーが勝ち、同点では設定順を保ちます。ストリーミング上の注意点：
  短いトリガーは、そのサフィックスが一致した時点で発火するため、その接頭辞を
  共有する長いトリガーが完成する前に発火します。
- `action.type` は `shell`（`command` を `/bin/sh -c` 経由で実行）または `log`
  （`message` をトップレベルの `logPath` に追記し、`logPath` が null の場合は
  出力します）です。コマンドの無い shell アクションやその他の種別は拒否されます。
- `context` は任意です。`appBundleId` と `processName` はそれぞれ null 可で、
  null はワイルドカードを意味します。マッチングはこの MVP ではスタブです。
  すべてのルールは常にマッチしますが、フィールドは存在し、デコードとテストが
  済んでいるため、将来のアプリ別マッチャーを後から差し込めます。
- 不正な設定（壊れた JSON、空のトリガー、未知のアクション種別、ファイル欠落）は
  大きく失敗します。デーモンはエラーを stderr に出力し、非ゼロで終了します。

アクションにシークレットやネットワーク呼び出しを入れてはいけません。

## macOS キー取得フック（将来対応、MVP 対象外）

`Sources/keypipe/MacKeyTap.swift` がフックポイントをドキュメント化しています。
将来の変更では keyDown イベント用の CGEventTap を作成し、各 CGEvent を入力文字に
変換して `TriggerMatcher.feed` に流します。ヒットしたら `rule.action` を実行
します。この取得にはアクセシビリティ許可（`AXIsProcessTrusted`）が必要で、
`#if os(macOS)` でのみコンパイルされます。マッチャー自体はすでにデーモンの
パスに配線されています（`main.swift` が読み込んだルールから構築し、ヒット時に
アクションを実行します）。取得が入るまでは、`--feed-stdin` と `--smoke-feed`
で Linux 上のそのパスを検証し、純粋な `TriggerMatcher` のバッファパイプラインは
Accessibility API を使わない単体テストで検証します。

## 構成

- `Package.swift`: Swift パッケージ `keypipe`、実行ターゲット `keypipe`、
  テストターゲット `keypipeTests`。
- `Sources/keypipe/main.swift`: エントリーポイント、`--config` 解析、`keypipe
  started` ログ、SIGINT/SIGTERM 処理、シグナル受信までの実行ループ、および
  マッチャーに流してアクションを実行する `--feed-stdin` と `--smoke-feed`
  の開発用入力パス。
- `Sources/keypipe/Config.swift`: JSON スキーマ型と境界検証付きの
  `loadConfig(path:)`。
- `Sources/keypipe/Actions.swift`: マッチしたルールの `shell`／`log` アクションを
  実行する `runAction(_:logPath:)`。
- `Sources/keypipe/Context.swift`: 任意のルール別コンテキストと、常に真を返す
  スタブマッチャー。
- `Sources/keypipe/Trigger.swift`: 純粋なトリガーバッファマッチャー
  （`feed`／`reset`／`buffer`、`triggerMaxBuffer` 容量、最長マッチ優先）。
- `Sources/keypipe/MacKeyTap.swift`: 将来の CGEvent フックのドキュメント。
- `Tests/keypipeTests/`: トリガー、コンテキスト、設定の単体テスト。
- `config.example.json`: `@@@` を `echo keypipe-triggered` にマッピングする例。

## フォーマットとテスト

```sh
swift test
swift-format lint --strict --recursive Sources Tests
```

`swift-format` がフォーマッタであり、リポジトリルートの `.swift-format` で
スタイル（4 スペース）を固定しています。上記の lint は終了コード 0 である
必要があります。Linux ではボックスのツールチェーンに追加で
`LD_LIBRARY_PATH=/workspace/keypipe-mvp/scratch/swift-lib` が必要です
（そのディレクトリが存在する場合、`verify.sh` がエクスポートします）。

## 検証

プロジェクトローカルの検証スキルは `.claude/skills/verify-keypipe/` にあります
（`SKILL.md`、`verify.sh`、`features/`）。完全なドライブは以下で実行します。

```sh
REPO=/workspace/keypipe ./verify.sh
```
