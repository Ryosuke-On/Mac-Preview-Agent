import SwiftUI
import WebKit
import AppKit

// Shared process pool — all MarkdownMessageView instances share one web content process.
private let _mdPool = WKProcessPool()

/// WKWebView subclass that forwards scrollWheel events to its superview so the
/// enclosing SwiftUI ScrollView in ChatView can scroll even when the cursor is
/// hovering over rendered markdown content.
///
/// Also implements edge auto-scroll during a text-selection drag: when the user
/// drags a selection to the top/bottom edge of the chat's visible area, the
/// enclosing scroll view scrolls so the selection can be extended past the fold
/// (so copying long passages no longer stops at the visible boundary).
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // MARK: - Auto-scroll while drag-selecting

    private var dragMonitor: Any?
    /// True only for a drag that began inside this web view's content (i.e. a
    /// text selection), so other web views / the splitter don't trigger scrolling.
    private var draggingInSelf = false
    private var autoScrollTimer: Timer?
    /// Window-points to advance per tick; sign already resolved for direction.
    private var autoScrollVelocity: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installDragMonitor() } else { removeDragMonitor() }
    }

    deinit { removeDragMonitor() }

    private func installDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleSelectionDrag(event)
            return event
        }
    }

    private func removeDragMonitor() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        stopAutoScroll()
    }

    private func handleSelectionDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Check whether the click location falls within this view's frame
            // in window coordinates — more reliable than hitTest for WKWebView
            // whose internal subviews are managed by a separate web process.
            if let win = window {
                let ptInSelf = convert(event.locationInWindow, from: nil)
                draggingInSelf = bounds.contains(ptInSelf) && win === self.window
            } else {
                draggingInSelf = false
            }
        case .leftMouseDragged:
            guard draggingInSelf else { return }
            updateAutoScroll(for: event)
        case .leftMouseUp:
            draggingInSelf = false
            stopAutoScroll()
        default:
            break
        }
    }

    /// Set the scroll velocity based on how far past the top/bottom edge the
    /// pointer is. Zero velocity (pointer inside the safe band) stops scrolling.
    private func updateAutoScroll(for event: NSEvent) {
        guard let scrollView = enclosingScrollView else { stopAutoScroll(); return }
        let clip = scrollView.contentView
        let frameInWindow = clip.convert(clip.bounds, to: nil)
        let py = event.locationInWindow.y          // window coords, y increases upward
        let margin: CGFloat = 28
        let maxSpeed: CGFloat = 20                  // points per tick

        var velocity: CGFloat = 0
        if py > frameInWindow.maxY - margin {       // near top → reveal earlier content
            velocity = -min(maxSpeed, max(2, py - (frameInWindow.maxY - margin)))
        } else if py < frameInWindow.minY + margin { // near bottom → reveal later content
            velocity = min(maxSpeed, max(2, (frameInWindow.minY + margin) - py))
        }

        autoScrollVelocity = velocity
        if velocity == 0 { stopAutoScroll() } else { startAutoScroll() }
    }

    private func startAutoScroll() {
        guard autoScrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepAutoScroll()
        }
        // .eventTracking so the timer keeps firing during the drag's tracking loop.
        RunLoop.current.add(t, forMode: .eventTracking)
        RunLoop.current.add(t, forMode: .default)
        autoScrollTimer = t
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollVelocity = 0
    }

    private func stepAutoScroll() {
        guard autoScrollVelocity != 0,
              let scrollView = enclosingScrollView,
              let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        // Flipped document (SwiftUI ScrollView): +velocity (near bottom) scrolls down.
        let newY = doc.isFlipped ? origin.y + autoScrollVelocity
                                 : origin.y - autoScrollVelocity
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        origin.y = min(maxY, max(0, newY))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// WKWebView-based markdown renderer with KaTeX math support.
/// Supports full drag-to-select text (fixing the per-block selection limit of MarkdownUI).
struct MarkdownMessageView: NSViewRepresentable {
    let markdown: String
    var highlight: String = ""
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator($height) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = _mdPool
        cfg.userContentController.add(context.coordinator, name: "h")
        cfg.userContentController.add(context.coordinator, name: "cite")
        let wv = PassthroughWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        // Transparent background so it blends with the SwiftUI background.
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = .clear }
        context.coordinator.pendingHighlight = highlight
        context.coordinator.loadIfNeeded(makeHTML(), into: wv)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.heightBinding = $height
        context.coordinator.loadIfNeeded(makeHTML(), into: wv)
        context.coordinator.applyHighlight(highlight, to: wv)
    }

    // MARK: - HTML

    private func makeHTML() -> String {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // 1) Protect math regions: marked.js collapses `\\` → `\` (markdown escape rule),
        //    which breaks LaTeX row separators like in pmatrix/bmatrix. Pre-escape all
        //    backslashes inside `$$...$$` and `$...$` so the right number survives.
        // 2) Replace [[cite:N|quote]] markers with inline HTML badges + sources list.
        let mathProtected = protectMathBackslashes(in: markdown)
        let (processedMD, _) = processCitations(in: mathProtected)

        // JSONEncoder encodes String as a proper JSON string literal (with quotes + escaping).
        // Using JSONEncoder instead of JSONSerialization because JSONSerialization throws
        // an ObjC NSException (not a Swift error) when given a bare String as root object,
        // and try? cannot catch NSExceptions — crashing the app.
        guard let d = try? JSONEncoder().encode(processedMD),
              let j = String(data: d, encoding: .utf8) else { return "<p>(render error)</p>" }

        let fg    = dark ? "#e5e5e5" : "#1a1a1a"
        let cBg   = dark ? "rgba(255,255,255,.10)" : "rgba(0,0,0,.06)"
        let preBg = dark ? "rgba(255,255,255,.07)" : "rgba(0,0,0,.04)"
        let qBd   = dark ? "rgba(255,255,255,.30)" : "rgba(0,0,0,.25)"
        let qFg   = dark ? "#aaa"  : "#666"
        let tdBd  = dark ? "#444"  : "#ddd"
        let thBg  = dark ? "rgba(255,255,255,.05)" : "rgba(0,0,0,.03)"

        return """
        <!DOCTYPE html><html>
        <head><meta charset="UTF-8">
        <link rel="stylesheet"
              href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script defer
                src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script defer
                src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
                onload="onKTX()"></script>
        <script src="https://cdn.jsdelivr.net/npm/marked@13/marked.min.js"></script>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        html,body{background:transparent;color:\(fg);
          font-family:-apple-system,"Helvetica Neue",sans-serif;
          font-size:13px;line-height:1.6;word-break:break-word;cursor:text}
        p{margin-bottom:6px}
        h1,h2,h3{font-weight:600;margin-top:10px;margin-bottom:4px}
        h1{font-size:1.4em}h2{font-size:1.2em}h3{font-size:1.05em}
        code{font-family:"SF Mono",Menlo,monospace;font-size:.9em;
             background:\(cBg);padding:1px 4px;border-radius:3px}
        pre{background:\(preBg);border-radius:6px;padding:10px;
            margin:4px 0;overflow-x:auto}
        pre code{background:none;padding:0;font-size:.88em}
        ul,ol{padding-left:1.5em;margin-bottom:6px}li{margin:1px 0}
        blockquote{border-left:3px solid \(qBd);
                   padding-left:8px;color:\(qFg);margin:4px 0}
        a{color:#4a9eff}
        table{border-collapse:collapse;margin:6px 0;width:100%}
        td,th{border:1px solid \(tdBd);padding:4px 8px}
        th{font-weight:600;background:\(thBg)}
        .katex-display{overflow-x:auto;overflow-y:hidden;padding:6px 0;max-width:100%}
        .katex-display>.katex{white-space:normal}
        .katex .mord{white-space:nowrap}
        mark.pc-hl{background:#ffe082;color:#000;padding:0 2px;border-radius:2px}
        a.pc-cite{display:inline-block;background:rgba(74,158,255,.18);color:#4a9eff;
          text-decoration:none;font-size:.8em;font-weight:600;
          padding:0 5px;margin:0 1px;border-radius:8px;cursor:pointer;
          vertical-align:baseline;line-height:1.5;border:1px solid rgba(74,158,255,.35)}
        a.pc-cite:hover{background:rgba(74,158,255,.32)}
        a.pc-web{display:inline-block;background:rgba(120,200,140,.18);color:#3aa55c;
          text-decoration:none;font-size:.8em;font-weight:600;
          padding:0 5px 0 4px;margin:0 1px;border-radius:8px;cursor:pointer;
          vertical-align:baseline;line-height:1.5;border:1px solid rgba(120,200,140,.4)}
        a.pc-web:hover{background:rgba(120,200,140,.32)}
        a.pc-web:before{content:"\\1F310\\00A0"}  /* 🌐 + nbsp */
        .pc-sources{margin-top:14px;padding-top:10px;border-top:1px solid \(tdBd);
          font-size:.88em;color:\(qFg)}
        .pc-sources-title{font-weight:600;margin-bottom:4px;color:\(fg);font-size:.95em}
        .pc-sources ol{padding-left:1.4em;margin:0}
        .pc-sources li{margin:2px 0}
        </style></head>
        <body><div id="r"></div>
        <script>
        const md=\(j);
        document.getElementById('r').innerHTML=marked.parse(md,{breaks:false});
        function rpt(){
          const h=document.documentElement.scrollHeight;
          window.webkit.messageHandlers.h.postMessage(h);
        }
        function onKTX(){
          renderMathInElement(document.body,{
            delimiters:[
              {left:'$$',right:'$$',display:true},
              {left:'$',right:'$',display:false},
              {left:'\\\\(',right:'\\\\)',display:false},
              {left:'\\\\[',right:'\\\\]',display:true}
            ],throwOnError:false
          });
          rpt();
        }
        // ── Search highlight ──
        function clearHL(){
          document.querySelectorAll('mark.pc-hl').forEach(m=>{
            const p=m.parentNode;
            p.replaceChild(document.createTextNode(m.textContent),m);
            p.normalize();
          });
        }
        function setHL(q){
          clearHL();
          if(!q) return 0;
          const root=document.getElementById('r');
          if(!root) return 0;
          const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{
            acceptNode:n=>{
              const t=n.parentNode && n.parentNode.tagName;
              if(t==='SCRIPT'||t==='STYLE'||t==='MARK') return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          const nodes=[]; let n;
          while(n=w.nextNode()) nodes.push(n);
          const lq=q.toLowerCase();
          let count=0;
          nodes.forEach(node=>{
            const t=node.textContent;
            const lt=t.toLowerCase();
            let i=lt.indexOf(lq);
            if(i<0) return;
            const frag=document.createDocumentFragment();
            let last=0;
            while(i>=0){
              if(i>last) frag.appendChild(document.createTextNode(t.substring(last,i)));
              const m=document.createElement('mark');
              m.className='pc-hl';
              m.textContent=t.substring(i,i+q.length);
              frag.appendChild(m); count++;
              last=i+q.length;
              i=lt.indexOf(lq,last);
            }
            if(last<t.length) frag.appendChild(document.createTextNode(t.substring(last)));
            node.parentNode.replaceChild(frag,node);
          });
          return count;
        }
        // ── Citation clicks (PDF + Web) ──
        document.addEventListener('click',e=>{
          const pdfA=e.target.closest('a.pc-cite');
          const webA=e.target.closest('a.pc-web');
          const a=pdfA||webA;
          if(!a) return;
          e.preventDefault();
          if(!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cite)) return;
          if(pdfA){
            const page=parseInt(a.getAttribute('data-page'),10);
            const quote=a.getAttribute('data-quote')||'';
            window.webkit.messageHandlers.cite.postMessage({kind:'pdf',page:page,quote:quote});
          } else {
            const url=a.getAttribute('data-url')||'';
            window.webkit.messageHandlers.cite.postMessage({kind:'web',url:url});
          }
        });
        // Report height when layout settles, and whenever the container resizes.
        window.addEventListener('load',rpt);
        if(typeof ResizeObserver!=='undefined'){
          new ResizeObserver(rpt).observe(document.getElementById('r'));
        }
        </script>
        </body></html>
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var heightBinding: Binding<CGFloat>
        private(set) var lastHTML = ""
        private var lastHighlight = ""
        var pendingHighlight = ""
        private var didFinishLoad = false

        init(_ b: Binding<CGFloat>) { heightBinding = b }

        func loadIfNeeded(_ html: String, into wv: WKWebView) {
            guard html != lastHTML else { return }
            lastHTML = html
            didFinishLoad = false
            lastHighlight = ""  // reset; will be reapplied after load
            wv.loadHTMLString(html, baseURL: nil)
        }

        func applyHighlight(_ q: String, to wv: WKWebView) {
            pendingHighlight = q
            guard didFinishLoad, q != lastHighlight else { return }
            lastHighlight = q
            let encoded = (try? String(data: JSONEncoder().encode(q), encoding: .utf8)) ?? "\"\""
            wv.evaluateJavaScript("setHL(\(encoded))") { _, _ in }
        }

        // Fallback height via navigation delegate (fires after DOMContentLoaded).
        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            didFinishLoad = true
            wv.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] v, _ in
                if let h = v as? Double {
                    DispatchQueue.main.async {
                        self?.heightBinding.wrappedValue = max(20, CGFloat(h))
                    }
                }
            }
            // Re-apply highlight after reload.
            if !pendingHighlight.isEmpty {
                let q = pendingHighlight
                lastHighlight = ""
                applyHighlight(q, to: wv)
            }
        }

        // Primary height reporting via postMessage from JS.
        // Also handles citation clicks (handler name: "cite").
        func userContentController(_ c: WKUserContentController,
                                   didReceive m: WKScriptMessage) {
            switch m.name {
            case "h":
                if let h = m.body as? Double {
                    DispatchQueue.main.async {
                        self.heightBinding.wrappedValue = max(20, CGFloat(h))
                    }
                }
            case "cite":
                guard let body = m.body as? [String: Any] else { return }
                let kind = (body["kind"] as? String) ?? "pdf"
                if kind == "web", let urlStr = body["url"] as? String,
                   let url = URL(string: urlStr) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                } else if let page = body["page"] as? Int {
                    let quote = (body["quote"] as? String) ?? ""
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .pcJumpToCitation,
                            object: nil,
                            userInfo: ["page": page, "quote": quote])
                    }
                }
            default: break
            }
        }
    }
}

// MARK: - Citation marker processing

enum ParsedCitation: Equatable {
    case pdf(page: Int, quote: String)
    case web(url: String, label: String)
}

/// Replaces `[[cite:N|quote]]` and `[[web:URL|label]]` markers with inline HTML badges
/// and appends a "出典" section listing each citation. Returns the rewritten markdown
/// and the list of citations in document order.
func processCitations(in md: String) -> (markdown: String, citations: [ParsedCitation]) {
    // Combined pattern. Group 1: kind (cite|web), 2: page-or-url, 3: quote-or-label.
    let pattern = #"\[\[(cite|web):([^|\]]+?)\|(.+?)\]\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return (md, [])
    }
    let ns = md as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    let matches = regex.matches(in: md, options: [], range: fullRange)
    guard !matches.isEmpty else { return (md, []) }

    var result = ""
    var citations: [ParsedCitation] = []
    var cursor = 0

    for (i, m) in matches.enumerated() {
        if m.range.location > cursor {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
        }
        let kind = ns.substring(with: m.range(at: 1))
        let key = ns.substring(with: m.range(at: 2))
        let payload = ns.substring(with: m.range(at: 3))
        let idx = i + 1
        if kind == "web" {
            citations.append(.web(url: key, label: payload))
            let urlAttr = htmlEscapeAttr(key)
            // Keep the label inline so the message reads on its own, then the badge.
            let lText = htmlEscapeText(payload)
            result += "\(lText)<a href=\"#\" class=\"pc-web\" data-url=\"\(urlAttr)\">[\(idx)]</a>"
        } else {
            let page = Int(key) ?? 0
            citations.append(.pdf(page: page, quote: payload))
            let qAttr = htmlEscapeAttr(payload)
            // Keep the quoted text inline so the message reads on its own, then the badge.
            let qText = htmlEscapeText(payload)
            result += "\(qText)<a href=\"#\" class=\"pc-cite\" data-page=\"\(page)\" data-quote=\"\(qAttr)\">[\(idx)]</a>"
        }
        cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    }

    // Append sources list (raw HTML — marked.js passes inline/block HTML through).
    var src = "\n\n<div class=\"pc-sources\">"
    src += "<div class=\"pc-sources-title\">出典</div><ol>"
    for c in citations {
        switch c {
        case .pdf(let page, let quote):
            let q = htmlEscapeText(quote)
            let qAttr = htmlEscapeAttr(quote)
            src += "<li><a href=\"#\" class=\"pc-cite\" data-page=\"\(page)\" data-quote=\"\(qAttr)\">p.\(page)</a> — \(q)</li>"
        case .web(let url, let label):
            let l = htmlEscapeText(label)
            let urlAttr = htmlEscapeAttr(url)
            let urlText = htmlEscapeText(displayHost(url))
            src += "<li><a href=\"#\" class=\"pc-web\" data-url=\"\(urlAttr)\">\(l)</a> — <span style=\"opacity:.7\">\(urlText)</span></li>"
        }
    }
    src += "</ol></div>"
    return (result + src, citations)
}

/// Extract host (e.g., "example.com") from a URL string for compact display.
private func displayHost(_ urlStr: String) -> String {
    URL(string: urlStr)?.host ?? urlStr
}

private func htmlEscapeAttr(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "'", with: "&#39;")
}

private func htmlEscapeText(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

/// Doubles every backslash inside `$$...$$` and `$...$` regions so that marked.js's
/// markdown-escape pass (`\\` → `\`) leaves the LaTeX intact. Without this, matrix row
/// separators (`\\`) and other LaTeX commands collapse and KaTeX renders the matrix on
/// a single line. The delimiters themselves don't contain backslashes, so they pass
/// through untouched.
func protectMathBackslashes(in s: String) -> String {
    // Match $$...$$ (multi-line, non-greedy) OR $...$ (single-line, no embedded $ or \n).
    // Processing in one pass with two alternatives ensures $$ blocks are consumed before
    // single $ tries to match part of one.
    let pattern = #"(\$\$[\s\S]+?\$\$)|(\$[^\n$]+?\$)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
    let ns = s as NSString
    let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }

    var result = ""
    var cursor = 0
    for m in matches {
        if m.range.location > cursor {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
        }
        let part = ns.substring(with: m.range)
        // Double every backslash inside the math region. Delimiters ($ or $$) have none.
        let escaped = part.replacingOccurrences(of: "\\", with: "\\\\")
        result += escaped
        cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    }
    return result
}
