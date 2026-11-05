# DeckReel

発表者ノート付きPowerPointから、VOICEVOXのナレーション付きMP4を作るmacOS用CLIです。

## 使い方

1. Microsoft PowerPointと、利用する音声を含むVOICEVOX EngineをMacに用意し、Engineを起動します。
2. `deckreel --list-speakers` で話者・スタイルIDを確認します。
3. 原稿を発表者ノートに記載したPPTXを指定します。以下の `3` は例なので、使いたいIDに置き換えてください。

```sh
./deckreel --list-speakers
./deckreel presentation.pptx --speaker 3 --output output.mp4
```

初回はmacOSの「プライバシーとセキュリティ → オートメーション」でPowerPointへの操作を許可してください。
資料はローカルで処理します。Engineの既定接続先は `http://127.0.0.1:50021` です。

## 機能

- PPTXから順序とノート本文を抽出。非表示スライドは除外。
- PowerPointからPDFを自動出力し、1080p・30fps・H.264/AACのMP4を生成。
- VOICEVOXの話者・スタイル、速度、読みの置換辞書を指定。
- ノートが空なら3秒の無音、読み上げ後は0.5秒の余白（設定可能）。
- スライド単位のキャッシュで差分再生成と失敗後の再開。
- 既存の出力は `--overwrite` なしでは上書きしません。

```sh
./deckreel presentation.pptx --speaker 3 --speed 1.1 --dictionary readings.json
./deckreel presentation.pptx --speaker 3 --empty-notes skip
./deckreel presentation.pptx --speaker 3 --overwrite
./deckreel --help
```

辞書は配列順に適用する単純な文字列置換です。VOICEVOXの共有ユーザー辞書は変更しません。

```json
[
  {"from": "API", "to": "エーピーアイ"},
  {"from": "Kubernetes", "to": "クバネティス"}
]
```

中間成果物は既定で入力フォルダの `work/<資料名>-<パスのハッシュ>/` に保存します。
再実行時も同じフォルダを使ってください。保存した原稿や音声はGitに登録しないでください。
使う音声の利用規約・クレジットを確認してください。使用した音声情報とクレジット候補は作業フォルダの `voice.json` に保存されます。

## ビルドと配布

開発時だけmacOS 12以降、Go 1.23以降、Xcode Command Line Toolsが必要です。

```sh
./scripts/build.sh
./dist/deckreel --help
```

本体とAVFoundation/PDF描画用の補助実行物を1ファイルにまとめます。利用時はGo・Swift・Python・FFmpegのインストールは不要です。
PowerPointとVOICEVOX Engineは別途必要です。補助実行物は初回にユーザーのキャッシュへ展開します。

現在は初期実装です。CIはGoのテストとmacOSのネイティブ動画処理を対象にしていますが、PowerPoint実機操作、実際のVOICEVOXの聴取品質、配布用署名・公証は別途確認が必要です。
開発ビルドの署名はアドホックで、正式リリースとしての配布検証は未完了です。

[要件](docs/requirements.md)・[設計](docs/design.md)・[開発と検証](docs/development.md)を参照してください。
