import SwiftUI
import PDFKit
import AppKit
import Combine

// MARK: - PDFView subclass with "Ask Claude" menu item

final class ContextMenuPDFView: PDFView {
    /// PDFView builds its right-click menu internally; the safest hook is
    /// `menu(for:)`, which is consulted for every contextual menu request.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let sel = currentSelection?.string,
           !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(title: "Claude に質問…",
                                  action: #selector(askClaudeAboutSelection(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc func askClaudeAboutSelection(_ sender: Any?) {
        guard let sel = currentSelection else { return }
        let text = sel.string ?? ""
        guard !text.isEmpty else { return }
        var page: Int? = nil
        if let firstPage = sel.pages.first, let doc = document {
            page = doc.index(for: firstPage) + 1
        }
        var info: [String: Any] = ["text": text]
        if let page { info["page"] = page }
        NotificationCenter.default.post(name: .pcAskAboutSelection, object: nil, userInfo: info)
    }
}

// MARK: - Find controller (shared between SwiftUI find bar and PDFKitContainer)

final class PDFFindController: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var currentIndex = 0   // 1-based for display
    @Published var totalMatches = 0
    weak var pdfView: PDFView?
    private var matches: [PDFSelection] = []

    func show() { isVisible = true }

    func hide() {
        isVisible = false
        query = ""
        pdfView?.highlightedSelections = nil
        pdfView?.setCurrentSelection(nil, animate: false)
        matches = []
        currentIndex = 0
        totalMatches = 0
    }

    func search() {
        guard let doc = pdfView?.document else {
            matches = []; totalMatches = 0; currentIndex = 0; return
        }
        let q = query
        if q.isEmpty {
            pdfView?.highlightedSelections = nil
            matches = []; totalMatches = 0; currentIndex = 0; return
        }
        matches = doc.findString(q, withOptions: [.caseInsensitive])
        totalMatches = matches.count
        let colored = matches.map { sel -> PDFSelection in
            sel.color = NSColor.systemYellow.withAlphaComponent(0.55)
            return sel
        }
        pdfView?.highlightedSelections = colored
        if let first = matches.first {
            currentIndex = 1
            pdfView?.setCurrentSelection(first, animate: false)
            pdfView?.go(to: first)
        } else {
            currentIndex = 0
        }
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = currentIndex >= matches.count ? 1 : currentIndex + 1
        focusCurrent()
    }

    func prev() {
        guard !matches.isEmpty else { return }
        currentIndex = currentIndex <= 1 ? matches.count : currentIndex - 1
        focusCurrent()
    }

    private func focusCurrent() {
        let sel = matches[currentIndex - 1]
        pdfView?.setCurrentSelection(sel, animate: false)
        pdfView?.go(to: sel)
    }

    /// Jump to a citation (LLM-provided page + verbatim quote) and highlight the quote
    /// on that page. If the quote can't be found verbatim, falls back to page navigation.
    func jumpToCitation(page: Int, quote: String) {
        guard let pdfView, let doc = pdfView.document else { return }
        let pageIndex = max(0, min(doc.pageCount - 1, page - 1))
        guard let targetPage = doc.page(at: pageIndex) else { return }
        pdfView.go(to: targetPage)

        guard !quote.isEmpty else { return }
        // Try several progressively-shorter variants in case the LLM quoted with whitespace
        // or punctuation that doesn't appear verbatim in the PDF text layer.
        let candidates = [
            quote,
            quote.trimmingCharacters(in: .whitespacesAndNewlines),
            String(quote.prefix(40)),
            String(quote.prefix(24)),
        ]
        var found: PDFSelection?
        for c in candidates where !c.isEmpty {
            let all = doc.findString(c, withOptions: [.caseInsensitive])
            // Prefer matches on the target page.
            if let onPage = all.first(where: { sel in
                sel.pages.contains { doc.index(for: $0) == pageIndex }
            }) {
                found = onPage; break
            }
            if found == nil, let first = all.first { found = first }
        }
        if let sel = found {
            sel.color = NSColor.systemYellow.withAlphaComponent(0.55)
            pdfView.highlightedSelections = [sel]
            pdfView.setCurrentSelection(sel, animate: true)
            pdfView.go(to: sel)
        }
    }
}

// MARK: - SwiftUI wrapper with overlay find bar

struct PDFViewer: View {
    let url: URL
    @StateObject private var finder = PDFFindController()
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            PDFKitContainer(url: url, finder: finder)
            if finder.isVisible {
                findBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pcFind)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { finder.show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { findFieldFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pcJumpToCitation)) { note in
            guard let info = note.userInfo,
                  let page = info["page"] as? Int else { return }
            let quote = (info["quote"] as? String) ?? ""
            finder.jumpToCitation(page: page, quote: quote)
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.subheadline)
            TextField("PDF 内を検索", text: $finder.query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .frame(minWidth: 160)
                .focused($findFieldFocused)
                .onChange(of: finder.query) { _, _ in finder.search() }
                .onSubmit { finder.next() }
                .onExitCommand { close() }
            if finder.totalMatches > 0 {
                Text("\(finder.currentIndex)/\(finder.totalMatches)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !finder.query.isEmpty {
                Text("0/0").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button { finder.prev() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(finder.totalMatches == 0)
            Button { finder.next() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(finder.totalMatches == 0)
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.top, 10).padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { finder.hide() }
        findFieldFocused = false
    }
}

// MARK: - PDFKit container

struct PDFKitContainer: NSViewRepresentable {
    let url: URL
    let finder: PDFFindController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = ContextMenuPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.pageShadowsEnabled = true
        v.document = PDFDocument(url: url)
        finder.pdfView = v
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url {
            v.document = PDFDocument(url: url)
            finder.pdfView = v
        }
    }

    // MARK: - Coordinator: handles menu notifications

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private weak var pdfView: PDFView?

        func attach(to view: PDFView) {
            pdfView = view
            let nc = NotificationCenter.default
            let q  = OperationQueue.main
            observers = [
                nc.addObserver(forName: .pcPrint,      object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.printView(nil)
                },
                nc.addObserver(forName: .pcZoomIn,     object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.zoomIn(nil)
                },
                nc.addObserver(forName: .pcZoomOut,    object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.zoomOut(nil)
                },
                nc.addObserver(forName: .pcActualSize, object: nil, queue: q) { [weak self] _ in
                    guard let v = self?.pdfView else { return }
                    v.autoScales = false
                    v.scaleFactor = 1.0
                },
                nc.addObserver(forName: .pcZoomToFit,  object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.autoScales = true
                },
                nc.addObserver(forName: .pcFirstPage,  object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.goToFirstPage(nil)
                },
                nc.addObserver(forName: .pcPrevPage,   object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.goToPreviousPage(nil)
                },
                nc.addObserver(forName: .pcNextPage,   object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.goToNextPage(nil)
                },
                nc.addObserver(forName: .pcLastPage,   object: nil, queue: q) { [weak self] _ in
                    self?.pdfView?.goToLastPage(nil)
                },
            ]
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
