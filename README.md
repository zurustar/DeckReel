# DeckReel

発表者ノート付きPowerPointから、VOICEVOXのナレーション付きMP4を作るmacOS用アプリです。同じ処理をCLIでも使えます。

> [!NOTE]
> DeckReelはビルド済みのアプリを配布していません（Apple Developer IDでの署名・公証をしていないため）。
> 以下の手順で、お使いのMacでソースコードからビルドしてください。数分で終わります。

## 必要なもの

| 用途 | 必要なもの |
| --- | --- |
| 実行 | macOS 14以降、Microsoft PowerPoint、[VOICEVOX](https://voicevox.hiroshiba.jp/)（またはVOICEVOX Engine） |
| ビルド | Xcode Command Line Tools（Xcode本体は不要） |

Apple Silicon・IntelのどちらのMacでもビルドできます（ビルドしたMacのアーキテクチャ向けになります）。外部ライブラリは使わないので、ビルド時のネット接続も不要です。

## インストール（ソースからビルド）

1. Xcode Command Line Toolsを入れます（入っていれば不要）。

   ```sh
   xcode-select --install
   ```

2. ソースコードを取得し、リリース版をビルドします。

   ```sh
   git clone https://github.com/zurustar/DeckReel.git
   cd DeckReel
   git checkout v0.2.0
   make app
   ```

   `dist/DeckReel.app` ができます。

3. アプリをアプリケーションフォルダにコピーします。

   ```sh
   ditto dist/DeckReel.app /Applications/DeckReel.app
   ```

自分でビルドしたアプリはダウンロード扱いにならないため、Gatekeeperにブロックされずに起動できます。
ビルドのたびに署名の識別情報が変わるため、更新後の初回はPowerPointの操作許可を再度求められることがあります。

### 更新

```sh
cd DeckReel
git fetch --tags
git checkout <新しいバージョンのタグ>
make app
rm -rf /Applications/DeckReel.app   # 古いファイルが残ると署名が壊れるため、置き換える
ditto dist/DeckReel.app /Applications/DeckReel.app
```

## アプリで使う

1. Microsoft PowerPointと、利用する音声を含むVOICEVOXを用意し、VOICEVOXを起動します。
2. `DeckReel.app` を起動し、PPTXをウインドウにドロップします。
3. 話者・速度を選んで「動画を作成」を押します。

初回は「DeckReelがMicrosoft PowerPointを操作しようとしています」と表示されるので許可してください。
許可はDeckReelだけに与えられ、ターミナルに権限を付ける必要はありません。

## CLIで使う

CLIはターミナルから起動するため、オートメーションの許可は起動元のターミナル（ターミナル.app、iTerm、VS Codeなど）に対して求められます。
そのターミナルで動く他のスクリプトもPowerPointを操作できるようになる点に注意してください。

1. `make cli` でビルドし、`dist/deckreel` を使います（`PATH` の通った場所にコピーしてもかまいません）。
2. VOICEVOXまたはVOICEVOX Engineを起動し、`deckreel --list-speakers` で話者・スタイルIDを確認します。
3. 原稿を発表者ノートに記載したPPTXを指定します。以下の `3` は例なので、使いたいIDに置き換えてください。

```sh
./deckreel --list-speakers
./deckreel presentation.pptx --speaker 3 --output output.mp4
```

初回はmacOSの「プライバシーとセキュリティ → オートメーション」で、使っているターミナルにPowerPointの操作を許可してください。
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

## 開発

```sh
make app        # アプリ dist/DeckReel.app（macOS 14以降）
make cli        # CLI dist/deckreel
make run-app    # ビルドして起動
make test       # テスト（Swift Testing）
make help       # ターゲット一覧
```

Swiftだけで書かれたSwift Package Managerのパッケージです。アプリもCLIも1つの実行ファイルで、動画処理はmacOS標準のAVFoundationで行います。
署名は既定でアドホックです。`DECKREEL_SIGN_IDENTITY` に証明書の名前を指定すると、その証明書で署名します（公証は自動化していません）。

v0.2.0でGoからSwiftに移行しました。以前の作業フォルダのキャッシュは自動で作り直されます。
PowerPoint実機操作、VOICEVOXの聴取品質、長尺資料での確認は継続中です。

[要件](docs/requirements.md)・[設計](docs/design.md)・[開発と検証](docs/development.md)を参照してください。
