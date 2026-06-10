import SwiftUI
import AppKit

/// Image viewer with trackpad pinch-to-zoom and pan.
struct ImageViewer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20.0
        scroll.magnification = 1.0
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .windowBackgroundColor

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: url)
        imageView.frame = NSRect(origin: .zero,
                                 size: imageView.image?.size ?? NSSize(width: 400, height: 300))
        scroll.documentView = imageView
        context.coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let iv = scroll.documentView as? NSImageView {
            iv.image = NSImage(contentsOf: url)
            iv.frame = NSRect(origin: .zero,
                              size: iv.image?.size ?? NSSize(width: 400, height: 300))
        }
    }

    // MARK: - Coordinator: menu zoom / print notifications

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private weak var scrollView: NSScrollView?

        /// True only when this view belongs to the frontmost (key) window. Menu commands
        /// broadcast to every open window, so without this guard a single ⌘P would print
        /// every open document at once.
        private var isKey: Bool { scrollView?.window?.isKeyWindow == true }

        func attach(to scroll: NSScrollView) {
            scrollView = scroll
            let nc = NotificationCenter.default
            let q  = OperationQueue.main
            observers = [
                nc.addObserver(forName: .pcZoomIn,     object: nil, queue: q) { [weak self] _ in
                    guard let sv = self?.scrollView, sv.window?.isKeyWindow == true else { return }
                    sv.magnification = min(sv.maxMagnification, sv.magnification * 1.25)
                },
                nc.addObserver(forName: .pcZoomOut,    object: nil, queue: q) { [weak self] _ in
                    guard let sv = self?.scrollView, sv.window?.isKeyWindow == true else { return }
                    sv.magnification = max(sv.minMagnification, sv.magnification / 1.25)
                },
                nc.addObserver(forName: .pcActualSize, object: nil, queue: q) { [weak self] _ in
                    guard self?.isKey == true else { return }
                    self?.scrollView?.magnification = 1.0
                },
                nc.addObserver(forName: .pcZoomToFit,  object: nil, queue: q) { [weak self] _ in
                    guard let sv = self?.scrollView, sv.window?.isKeyWindow == true,
                          let iv = sv.documentView as? NSImageView,
                          let size = iv.image?.size, size.width > 0 else { return }
                    let fit = min(sv.bounds.width / size.width,
                                  sv.bounds.height / size.height)
                    sv.magnification = min(sv.maxMagnification, max(sv.minMagnification, fit))
                },
                nc.addObserver(forName: .pcPrint,      object: nil, queue: q) { [weak self] _ in
                    guard let sv = self?.scrollView, sv.window?.isKeyWindow == true,
                          let iv = sv.documentView as? NSImageView,
                          let image = iv.image else { return }
                    let op = NSPrintOperation(view: iv)
                    op.printInfo.isHorizontallyCentered = true
                    op.printInfo.isVerticallyCentered   = true
                    op.printInfo.scalingFactor = min(1.0,
                        op.printInfo.paperSize.width / image.size.width)
                    op.run()
                },
            ]
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
