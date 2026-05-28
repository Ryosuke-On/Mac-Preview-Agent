import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let fileURL: URL

    /// Persisted chat sidebar width in points. 0 means "not set yet" → use 1/4 of window.
    @AppStorage("chatPaneWidth") private var storedChatWidth: Double = 0
    @AppStorage("chatPaneVisible") private var chatVisible: Bool = true

    private let minViewer: CGFloat = 320
    private let minChat: CGFloat = 220
    private let maxChat: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let defaultChat = max(minChat, min(maxChat, total * 0.25))
            let chatW = clamp(
                storedChatWidth == 0 ? defaultChat : CGFloat(storedChatWidth),
                lower: minChat,
                upper: min(maxChat, max(minChat, total - minViewer))
            )
            HStack(spacing: 0) {
                viewerPane
                    .frame(width: chatVisible ? total - chatW - 1 : total)
                    .overlay(alignment: .topTrailing) {
                        if !chatVisible {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { chatVisible = true }
                            } label: {
                                Image(systemName: "sidebar.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(8)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("チャットパネルを表示 (⌘\\)")
                            .padding(12)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                if chatVisible {
                    SplitterHandle(
                        startWidth: chatW,
                        lower: minChat,
                        upper: min(maxChat, max(minChat, total - minViewer)),
                        onCommit: { storedChatWidth = Double($0) }
                    )
                    .frame(width: 1)
                    ChatView(fileURL: fileURL,
                             onHide: { withAnimation(.easeInOut(duration: 0.2)) { chatVisible = false } })
                        .frame(width: chatW)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: chatVisible)
        }
        // Observe chat-toggle notification posted by the menu (⌘\).
        .onReceive(NotificationCenter.default.publisher(for: .pcChatToggle)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { chatVisible.toggle() }
        }
        // Auto-reveal chat when user asks Claude about a PDF selection.
        .onReceive(NotificationCenter.default.publisher(for: .pcAskAboutSelection)) { _ in
            if !chatVisible {
                withAnimation(.easeInOut(duration: 0.2)) { chatVisible = true }
            }
        }
    }

    @ViewBuilder
    private var viewerPane: some View {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "pdf" {
            PDFViewer(url: fileURL)
        } else if ["md", "markdown", "txt"].contains(ext) {
            MarkdownViewer(url: fileURL)
        } else if isImageExt(ext) {
            ImageViewer(url: fileURL)
        } else if (try? Data(contentsOf: fileURL)) != nil {
            MarkdownViewer(url: fileURL)
        } else {
            Text("Cannot open \(fileURL.lastPathComponent)").foregroundStyle(.secondary)
        }
    }

    private func isImageExt(_ ext: String) -> Bool {
        ["png","jpg","jpeg","gif","tiff","tif","bmp","heic","heif","webp"].contains(ext)
    }

    private func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(upper, v))
    }
}

// MARK: - Splitter

/// 1px hairline divider with a wider invisible hit area + resize cursor.
private struct SplitterHandle: View {
    let startWidth: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    var onCommit: (CGFloat) -> Void
    @State private var hovering = false
    @State private var dragStartWidth: CGFloat? = nil

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color.secondary.opacity(hovering ? 0.5 : 0.25))
                .frame(width: 1)
        }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = dragStartWidth ?? startWidth
                    if dragStartWidth == nil { dragStartWidth = base }
                    let target = base - value.translation.width
                    onCommit(max(lower, min(upper, target)))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}
