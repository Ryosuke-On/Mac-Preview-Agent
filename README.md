# PreviewAgent

**Agentic viewing for any file.** PDF・画像・Markdown を閲覧しながら、Claude / Codex と対話できる macOS 用ファイルビューワです。ファイルを開くと右側にチャットサイドバーが現れ、そのファイルについて好きなエージェントに質問・要約・引用つき回答をさせられます。

<p align="center">
  <a href="https://github.com/Ryosuke-On/Mac-Preview-Agent/releases/latest">
    <img src="https://img.shields.io/github/v/release/Ryosuke-On/Mac-Preview-Agent?label=Download+DMG&style=for-the-badge&logo=apple&logoColor=white&color=007AFF" alt="Download DMG">
  </a>
</p>

## スクリーンショット

### ウェルカム画面 — ドラッグ＆ドロップ・最近開いたファイル

![welcome](docs/screenshot_welcome.png)

### PDF + チャット — 要約・質問・エージェント操作

![main](docs/screenshot_main.png)

### 引用バッジ — PDF 箇所へのジャンプ・Web リンク

![citations](docs/screenshot_citations.png)

---

## 主な機能

### ファイルビューワ

| 形式 | 機能 |
|------|------|
| **PDF** | PDFKit ベース。トラックパッドのピンチズーム・テキスト選択・システム翻訳・辞書がネイティブ動作。⌘F で PDF 内検索バー表示、マッチ箇所をハイライト。 |
| **画像** | PNG / JPEG / HEIC / GIF / WebP 等。ピンチズーム＆パン対応。対応エージェントでは画像を直接添付して認識・説明。 |
| **Markdown / テキスト** | NSTextView でレンダリング。⌘F でシステム標準の検索バー。翻訳・辞書・検索すべて利用可能。 |

### チャットサイドバー

- **Claude / Codex 切り替え** — ヘッダーのエージェントメニューで Claude と Codex を切り替え。Claude は常駐 `claude` subprocess、Codex は `codex exec --json` をターン単位で実行。
- **ストリーミング応答** — 回答がリアルタイムで流れ込む。途中で「停止」ボタンを押せばその時点で中断し、入力欄に送信済みテキストが復元される。
- **Markdown + 数式レンダリング** — 回答は marked.js + KaTeX で整形。コードブロック・表・行列（`\begin{pmatrix}` 等）もきれいに表示。
- **モデル選択** — Claude は Haiku / Sonnet / Opus、Codex は Default / GPT-5 Codex / GPT-5 を選択可能。エージェントごとに選択を記憶。
- **ファイル別チャット履歴** — 同じファイルを再度開けば前回の会話が復元。エージェントのセッション ID / thread ID も保存して続きから応答する。
- **ツール実行の可視化** — Read / Edit / Bash / WebSearch などのツール使用がチップ表示。Codex のシェル実行・ファイル変更・Web 検索・MCP 呼び出しも表示。
- **トークン & コスト表示** — ヘッダーに「累計 ↑Xk ↓Xk」、各応答の下に「↑X ↓X tokens」を表示。Claude はセッション累計コスト（USD）も表示。
- **チャット内検索** — チャット欄にフォーカスした状態で ⌘F。マッチ箇所が黄色ハイライト、件数を表示。
- **PDF テキスト選択→質問** — PDF でテキストを選択して右クリック→「AI に質問…」で、引用付きの質問文を自動入力。

### 引用バッジ（Citations）

エージェントの回答に含まれる `[[cite:ページ|引用]]` マーカーが青いバッジに変換される。クリックすると PDF がそのページに飛び、引用テキストをハイライト。

Web 検索・参照からの引用は `[[web:URL|ラベル]]` が緑の 🌐 バッジになり、クリックでブラウザが開く（Web 引用は Claude 利用時のみ）。

### ウェルカム画面

- ドラッグ＆ドロップでファイルを開く（点線枠エリア）
- 最近開いたファイル一覧（Finder アイコン付き）
- クリックで即座に再オープン

### メニュー統合

| メニュー | 操作 |
|---------|------|
| **ファイル** | ⌘O で開く、⌘P で印刷、ページ設定 |
| **表示** | ズームイン / アウト / 実際のサイズ / ウィンドウに合わせる、⌘F で検索 |
| **移動** | ← → で前後ページ、先頭・末尾ページ |

### レイアウト

- ビューワ：チャット = 初期 **3:1**。ドラッグで調整した幅は永続化（`@AppStorage`）。
- チャットパネルは非表示ボタンで畳める。非表示中は右上に再表示ボタンが浮遊。

---

## 必要なもの

- **macOS 14** 以上（macOS 15 / 26 で動作確認済み）
- **[Claude Code](https://docs.anthropic.com/ja/docs/claude-code)** CLI（Claude 利用時、`claude` コマンドが PATH 上にある状態）
- **Codex CLI**（Codex 利用時、`codex` コマンドが PATH 上にある状態。Codex.app 同梱 CLI も検出します）
- Xcode 15 以上（ビルド時）

> Claude Code が未インストールの場合は `npm install -g @anthropic-ai/claude-code` でインストールしてください。Codex は `codex login` 済みのローカル CLI を利用します。

### 認証

- **Claude** — ターミナルで `claude /login` を一度実行（OAuth）。または API キーを使う場合は `~/.config/previewagent/config.json` に置く：
  ```json
  { "anthropicApiKey": "sk-ant-...", "anthropicBaseUrl": "https://api.anthropic.com" }
  ```
  （`anthropicBaseUrl` は任意）
- **Codex** — **[Codex デスクトップアプリ](https://chatgpt.com/codex)に ChatGPT アカウントでログイン済みなら、追加の操作は不要**です。認証情報（`~/.codex/auth.json`）は Codex.app と `codex` CLI で共有され、PreviewAgent は同梱 CLI を使うためそのまま認証済みになります。CLI 単体で使う場合のみ、ターミナルで `codex login`（ブラウザ OAuth）または `codex login --with-api-key`（API キーを stdin で渡す）を実行してください。

---

## ダウンロード（ビルド済みアプリ）

[Releases ページ](https://github.com/Ryosuke-On/Mac-Preview-Agent/releases/latest) から `PreviewAgent-vX.Y.Z.dmg`（または最新ビルドの `PreviewAgent.dmg`）をダウンロードしてください。

### インストール手順

1. DMG をダブルクリックして開き、`PreviewAgent.app` を **Applications** にドラッグ
2. **ターミナルで以下を 1 回実行**（未署名アプリの隔離属性を解除。パスワードを聞かれます）：
   ```sh
   sudo xattr -dr com.apple.quarantine /Applications/PreviewAgent.app
   ```
3. Launchpad や Finder からダブルクリックで起動

### 「"PreviewAgent" は壊れているため開けません」と出た場合

未署名アプリに macOS が付ける `com.apple.quarantine` 属性のためで、アプリ自体は正常です。上の手順 2 のコマンドで隔離属性を解除してください。

---

## ビルド

```sh
# 依存ツール（XcodeGen）
brew install xcodegen

# プロジェクト生成 & ビルド
git clone https://github.com/Ryosuke-On/Mac-Preview-Agent.git
cd Mac-Preview-Agent
xcodegen generate
open PreviewAgent.xcodeproj   # Xcode で開いて ▶ ボタン
```

または CLI だけでビルド：

```sh
xcodebuild \
  -project PreviewAgent.xcodeproj \
  -scheme PreviewAgent \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

---

## アーキテクチャメモ

- **AppDelegate + NSHostingView** で NSWindow を手動管理（SwiftUI WindowGroup 非使用）。`.toolbar` はクラッシュするため NotificationCenter 経由でメニュー操作をルーティング。
- **claude CLI** を `--output-format stream-json --verbose` で常駐サブプロセスとして起動。`assistant` イベントの `message.usage` と `result` イベントの `usage` の両方からトークン数を収集。
- **codex CLI** は `codex exec --json` / `codex exec resume <thread_id>` をターンごとに起動し、JSONL の `thread.started` / `item.completed` / `turn.completed` から UI イベント、thread ID、トークン数を収集。サンドボックスは `-c sandbox_mode="workspace-write"` で初回・resume 両方に統一指定。
- **WKWebView（PassthroughWebView）** でチャットメッセージをレンダリング。KaTeX + marked.js を埋め込み。スクロールイベントは `nextResponder` へ転送。
- **PDFFindController** を ObservableObject として PDFKitContainer と SwiftUI find bar overlay が共有。
- **Vision 対応**: PNG/JPEG/GIF/WebP は直接 Base64 エンコード、HEIC/TIFF/BMP は NSImage→NSBitmapImageRep→PNG に変換してから送信。

---

## ライセンス

MIT
