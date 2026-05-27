# PreviewChat

macOS 用のファイルビューワ（PDF / 画像 / Markdown）に、Claude Code を組み込んだチャットサイドバーを付けたアプリです。ダブルクリックでファイルを開き、右側のチャット欄でそのファイルについて質問できます。Claude は同じフォルダ内の他のファイルを読み込んだり、要約 Markdown を書き出したりできます — Claude Code と同じエージェント能力をそのまま使えます。

![screenshot](docs/screenshot.png)

## 特徴

- **PDF**: PDFKit ベース。トラックパッドのピンチで拡大縮小、テキスト選択、システム標準の翻訳 / 調べる / 検索 (⌘F) がすべてネイティブ動作。
- **画像**: ピンチズーム & パン。
- **Markdown / テキスト**: `NSTextView` でレンダリング。検索バー、翻訳、辞書すべて利用可能。
- **チャットサイドバー**: `claude` CLI を `stream-json` モードで常駐サブプロセスとして起動。作業ディレクトリは開いたファイルの親フォルダ、システムプロンプトに現在のファイルパスを注入します。
- **ファイル別チャット履歴**: 同じファイルを再度開けば前回の会話が復元され、Claude 側も `--resume <session_id>` で同じ会話の続きから応答します。
- **モデル選択**: ヘッダーのプルダウンから Haiku / Sonnet / Opus を切り替え可能（文脈は維持）。
- **3:1 レイアウト**: ビューワ：チャットの幅比率は初期 3:1、ドラッグで調整した値は永続化されます。
- **Enter で送信 / Shift+Enter で改行**: チャット入力欄の標準動作。
- **ダブルクリックで起動**: `CFBundleDocumentTypes` で PDF / 画像 / Markdown / プレーンテキストに関連付け済。

## 必要なもの

- macOS 14 以上
- Xcode 15 以上（ビルド時）
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) (`claude` が PATH 上にあること)

## 認証

チャットは内部で `claude` CLI を呼び出すので、認証もそれに従います。

### 推奨: OAuth ログイン

ターミナルで一度だけ実行してください。

```sh
claude /login
```

資格情報は `~/.claude.json` に保存され、次回以降 GUI アプリからもそのまま使えます。

### 代替: API キー

カスタムエンドポイントを使いたい場合や、API キー方式を好む場合は `~/.config/previewchat/config.json` に以下を置くと、アプリ起動時にサブプロセスへ環境変数として渡されます。

```json
{
  "anthropicApiKey": "sk-ant-...",
  "anthropicBaseUrl": "https://api.anthropic.com"
}
```

ファイルがあればこちらが優先されます。

## ビルド

```sh
brew install xcodegen
git clone https://github.com/Ryosuke-On/Mac-Preview-ClaudeCode-Sidebar.git
cd Mac-Preview-ClaudeCode-Sidebar
xcodegen generate
xcodebuild -scheme PreviewChat -derivedDataPath build CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/PreviewChat.app
```

`PreviewChat.xcodeproj` は `project.yml` から `xcodegen` で生成するため、リポジトリには含めていません。

## ファイル関連付け

Finder で PDF を右クリック → **情報を見る** → **このアプリケーションで開く** → `PreviewChat.app` を選択 → **すべてを変更…** で、ダブルクリックで PreviewChat が開くようになります。

## 使い方のコツ

- 「この PDF の要点を 3 つにまとめて」のように、自然言語で質問するだけ。
- 「同じフォルダにある `notes.md` も参照して」と指示すれば Claude が読み込みます。
- 「要約を `summary.md` として保存して」と頼めばそのまま書き出します（`--permission-mode acceptEdits` で承認なしに書き込めます。挙動を厳格にしたい場合は [`ClaudeAgent.swift`](Sources/PreviewChat/ClaudeAgent.swift) を編集してください）。

## 依存ライブラリ

- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — チャット応答の Markdown レンダリングに使用

## ライセンス

MIT License — [LICENSE](LICENSE) を参照してください。
