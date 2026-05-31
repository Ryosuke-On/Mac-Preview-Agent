import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let fileURL: URL

    /// Persisted chat sidebar width in points. 0 means "not set yet" → use 1/4 of window.
    @AppStorage("chatPaneWidth") private var storedChatWidth: Double = 0
    @AppStorage("chatPaneVisible") private var chatVisible: Bool = true

    private let minViewer: CGFloat = 320
    /// Wide enough that the chat header (agent + model pickers, buttons) fits on one
    /// row and isn't crushed under the divider overlay at the narrowest setting.
    private let minChat: CGFloat = 340
    private let maxChat: CGFloat = 700
    /// Width of the draggable splitter column (full hit area, not just the hairline).
    private let splitterWidth: CGFloat = 11

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
                    .frame(width: chatVisible ? total - chatW : total)
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
                    ChatView(fileURL: fileURL,
                             onHide: { withAnimation(.easeInOut(duration: 0.2)) { chatVisible = false } })
                        .frame(width: chatW)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: chatVisible)
            // Draggable divider sits ON TOP of the boundary as an overlay, so SwiftUI
            // hit-testing routes mouse events to it instead of the adjacent panes.
            // (As a thin HStack column between two hosted NSViews it never received the
            // mouse-down — the neighbors claimed the hit region.)
            .overlay(alignment: .leading) {
                if chatVisible {
                    SplitterHandle(
                        startWidth: chatW,
                        lower: minChat,
                        upper: min(maxChat, max(minChat, total - minViewer)),
                        onCommit: { storedChatWidth = Double($0) }
                    )
                    .frame(width: splitterWidth)
                    .offset(x: total - chatW - splitterWidth / 2)
                }
            }
        }
        // Observe chat-toggle notification posted by the menu (⌘\).
        .onReceive(NotificationCenter.default.publisher(for: .pcChatToggle)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { chatVisible.toggle() }
        }
        // Auto-reveal chat when user asks the active agent about a PDF selection.
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

/// Draggable divider. Both the hairline drawing and the drag/cursor handling live
/// entirely inside an AppKit NSView. A SwiftUI `DragGesture` does not reliably receive
/// mouse events on a thin strip adjacent to the PDFView (itself a hosted NSView), and
/// mixing a SwiftUI `Rectangle` into the same ZStack puts a SwiftUI layer on top that
/// swallows the mouse-down before it reaches the NSView.
private struct SplitterHandle: View {
    let startWidth: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    var onCommit: (CGFloat) -> Void

    var body: some View {
        SplitterMouseView(startWidth: startWidth, lower: lower, upper: upper, onCommit: onCommit)
    }
}

private struct SplitterMouseView: NSViewRepresentable {
    let startWidth: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    var onCommit: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DragNSView {
        let v = DragNSView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {
        context.coordinator.currentWidth = startWidth
        context.coordinator.lower = lower
        context.coordinator.upper = upper
        context.coordinator.onCommit = onCommit
    }

    final class Coordinator {
        var currentWidth: CGFloat = 0
        var lower: CGFloat = 0
        var upper: CGFloat = 0
        var onCommit: (CGFloat) -> Void = { _ in }
    }

    final class DragNSView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Draw the hairline ourselves so no SwiftUI layer needs to sit on top.
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
        }

        // Guarantee this view wins hit-testing across its full bounds.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }

        // Use a tracking area (re-added on every layout) rather than cursor rects,
        // so the resize cursor covers the full width even as the view's frame moves
        // with the divider.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        // Run an explicit event-tracking loop rather than relying on mouseDragged
        // delivery, which is unreliable for a thin SwiftUI-hosted NSView wedged
        // next to the PDFView's own NSView.
        override func mouseDown(with event: NSEvent) {
            guard let c = coordinator, let window = self.window else { return }
            let baseWidth = c.currentWidth
            let startX = event.locationInWindow.x
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                               timeout: .greatestFiniteMagnitude,
                               mode: .eventTracking) { ev, stop in
                guard let ev = ev else { return }
                if ev.type == .leftMouseUp { stop.pointee = true; return }
                // Chat panel is on the right: dragging left (negative dx) widens it.
                let dx = ev.locationInWindow.x - startX
                let target = baseWidth - dx
                c.onCommit(max(c.lower, min(c.upper, target)))
            }
        }
    }
}
