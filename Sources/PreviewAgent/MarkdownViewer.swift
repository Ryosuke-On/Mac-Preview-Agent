import SwiftUI
import AppKit

/// Read-only markdown / text viewer using NSTextView so native services
/// (Translate, Look Up, Find ⌘F, Speech) work out of the box.
struct MarkdownViewer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        configure(tv)
        load(into: tv)
        context.coordinator.attach(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        load(into: tv)
    }

    private func configure(_ tv: NSTextView) {
        tv.isEditable = false
        tv.isSelectable = true
        if #available(macOS 15.0, *) {
            tv.writingToolsBehavior = .none
        }
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.allowsUndo = false
        tv.textContainerInset = NSSize(width: 24, height: 24)
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticDataDetectionEnabled = true
    }

    private func load(into tv: NSTextView) {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            tv.string = "(cannot read file)"
            return
        }
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            if let attr = try? NSAttributedString(
                markdown: raw,
                options: .init(interpretedSyntax: .full,
                               failurePolicy: .returnPartiallyParsedIfPossible)) {
                let mutable = NSMutableAttributedString(attributedString: attr)
                let size = tv.font?.pointSize ?? 14
                mutable.addAttribute(.font,
                                     value: NSFont.systemFont(ofSize: size),
                                     range: NSRange(location: 0, length: mutable.length))
                mutable.addAttribute(.foregroundColor,
                                     value: NSColor.labelColor,
                                     range: NSRange(location: 0, length: mutable.length))
                tv.textStorage?.setAttributedString(mutable)
                return
            }
        }
        tv.string = raw
    }

    // MARK: - Coordinator: menu zoom / print notifications

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private weak var textView: NSTextView?

        func attach(to tv: NSTextView) {
            textView = tv
            let nc = NotificationCenter.default
            let q  = OperationQueue.main
            observers = [
                nc.addObserver(forName: .pcZoomIn,     object: nil, queue: q) { [weak self] _ in
                    self?.adjustSize(by: +2)
                },
                nc.addObserver(forName: .pcZoomOut,    object: nil, queue: q) { [weak self] _ in
                    self?.adjustSize(by: -2)
                },
                nc.addObserver(forName: .pcActualSize, object: nil, queue: q) { [weak self] _ in
                    self?.setSize(14)
                },
                nc.addObserver(forName: .pcPrint,      object: nil, queue: q) { [weak self] _ in
                    self?.textView?.printView(nil)
                },
                nc.addObserver(forName: .pcFind,       object: nil, queue: q) { [weak self] _ in
                    // Trigger NSTextView's native find bar (usesFindBar = true).
                    guard let tv = self?.textView else { return }
                    tv.window?.makeFirstResponder(tv)
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    tv.performTextFinderAction(item)
                },
            ]
        }

        private func adjustSize(by delta: CGFloat) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let next = max(8, min(72, (tv.font?.pointSize ?? 14) + delta))
            tv.font = NSFont.systemFont(ofSize: next)
            storage.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: next),
                                 range: NSRange(location: 0, length: storage.length))
        }

        private func setSize(_ size: CGFloat) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            tv.font = NSFont.systemFont(ofSize: size)
            storage.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: size),
                                 range: NSRange(location: 0, length: storage.length))
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
