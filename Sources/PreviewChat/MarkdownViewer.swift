import SwiftUI
import AppKit

/// Read-only markdown / text viewer using NSTextView so native services
/// (Translate, Look Up, Find ⌘F, Speech) work out of the box.
struct MarkdownViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        configure(tv)
        load(into: tv)
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
                mutable.addAttribute(.font,
                                     value: NSFont.systemFont(ofSize: 14),
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
}
