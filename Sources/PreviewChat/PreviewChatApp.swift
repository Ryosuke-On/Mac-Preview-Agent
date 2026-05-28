import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Viewer notification names
// Menus post these; PDFViewer / MarkdownViewer / ImageViewer observe them.
extension NSNotification.Name {
    static let pcPrint      = NSNotification.Name("PreviewChat.print")
    static let pcZoomIn     = NSNotification.Name("PreviewChat.zoomIn")
    static let pcZoomOut    = NSNotification.Name("PreviewChat.zoomOut")
    static let pcActualSize = NSNotification.Name("PreviewChat.actualSize")
    static let pcZoomToFit  = NSNotification.Name("PreviewChat.zoomToFit")
    static let pcFirstPage  = NSNotification.Name("PreviewChat.firstPage")
    static let pcPrevPage   = NSNotification.Name("PreviewChat.prevPage")
    static let pcNextPage   = NSNotification.Name("PreviewChat.nextPage")
    static let pcLastPage   = NSNotification.Name("PreviewChat.lastPage")
    static let pcChatToggle = NSNotification.Name("PreviewChat.chatToggle")
    static let pcFind       = NSNotification.Name("PreviewChat.find")
    /// Posted with userInfo: ["page": Int (1-based), "quote": String]
    static let pcJumpToCitation = NSNotification.Name("PreviewChat.jumpToCitation")
    /// Posted with userInfo: ["text": String, "page": Int?]
    static let pcAskAboutSelection = NSNotification.Name("PreviewChat.askAboutSelection")
    /// Focus the chat input field (e.g. after inserting a quoted selection).
    static let pcFocusChatInput = NSNotification.Name("PreviewChat.focusChatInput")
}

// MARK: - App

@main
struct PreviewChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "viewer", for: URL.self) { $url in
            if let url = url {
                ContentView(fileURL: url)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                WelcomeView()
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        .commands {
            // ── File ────────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("開く…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            // .printItem は DocumentGroup 専用なので after: .newItem で File メニューに追加する
            CommandGroup(after: .newItem) {
                Divider()
                Button("プリント…") {
                    NotificationCenter.default.post(name: .pcPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("ページ設定…") {
                    NSPageLayout().runModal()
                }
            }

            // ── View ────────────────────────────────────────────────
            CommandMenu("表示") {
                Button("拡大") {
                    NotificationCenter.default.post(name: .pcZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("縮小") {
                    NotificationCenter.default.post(name: .pcZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("実際のサイズ") {
                    NotificationCenter.default.post(name: .pcActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("ページに合わせる") {
                    NotificationCenter.default.post(name: .pcZoomToFit, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

                Button("チャットパネルを隠す / 表示") {
                    NotificationCenter.default.post(name: .pcChatToggle, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
            }

            // ── Go (PDF page navigation) ────────────────────────────
            CommandMenu("移動") {
                Button("最初のページ") {
                    NotificationCenter.default.post(name: .pcFirstPage, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("前のページ") {
                    NotificationCenter.default.post(name: .pcPrevPage, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("次のページ") {
                    NotificationCenter.default.post(name: .pcNextPage, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("最後のページ") {
                    NotificationCenter.default.post(name: .pcLastPage, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .plainText,
                                     UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            NSApp.sendAction(#selector(AppDelegate.openURL(_:)), to: nil, from: url as Any)
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(for: url) }
    }

    @objc func openURL(_ sender: Any?) {
        if let url = sender as? URL { openWindow(for: url) }
    }

    private func openWindow(for url: URL) {
        RecentFiles.record(url)
        let controller = NSWindowController(window: makeWindow(for: url))
        controller.showWindow(nil)
    }

    private func makeWindow(for url: URL) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.title = url.lastPathComponent
        window.center()
        let root = ContentView(fileURL: url)
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - Recent files store

enum RecentFiles {
    private static let key = "recentFiles"
    private static let maxCount = 12

    static func load() -> [URL] {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return arr.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func record(_ url: URL) {
        var existing = load().filter { $0 != url }
        existing.insert(url, at: 0)
        if existing.count > maxCount { existing = Array(existing.prefix(maxCount)) }
        UserDefaults.standard.set(existing.map { $0.absoluteString }, forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Welcome view

struct WelcomeView: View {
    @State private var recents: [URL] = RecentFiles.load()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Hero ──
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("PreviewChat")
                    .font(.largeTitle).fontWeight(.semibold)
                Text("PDF・画像・Markdown を Claude と一緒に読む")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        openFilePanel()
                    } label: {
                        Label("ファイルを開く", systemImage: "folder")
                            .padding(.horizontal, 8)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                    Text("または ここにドラッグ&ドロップ")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        dropTargeted ? Color.accentColor : Color.secondary.opacity(0.18),
                        style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(dropTargeted ? Color.accentColor.opacity(0.06) : .clear))
            )
            .padding(20)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }

            // ── Recents ──
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("最近のファイル").font(.headline)
                        Spacer()
                        Button("消去") {
                            RecentFiles.clear()
                            recents = []
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(recents, id: \.self) { url in
                                RecentRow(url: url) {
                                    NSApp.sendAction(#selector(AppDelegate.openURL(_:)), to: nil, from: url as Any)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 16)
            } else {
                Spacer()
            }
        }
        .padding(.top, 12)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .plainText,
                                     UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            NSApp.sendAction(#selector(AppDelegate.openURL(_:)), to: nil, from: url as Any)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(AppDelegate.openURL(_:)), to: nil, from: url as Any)
            }
        }
        return true
    }
}

// MARK: - Recent file row

private struct RecentRow: View {
    let url: URL
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 13))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2).foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.secondary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
