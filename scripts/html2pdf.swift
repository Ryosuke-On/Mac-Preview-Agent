import Cocoa
import WebKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: html2pdf <input.html> <output.pdf>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Loader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let output: URL
    init(output: URL) {
        // A4 at 72dpi: 595 x 842
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: cfg)
        self.output = output
        super.init()
        webView.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give webfonts/layout a beat to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let pcfg = WKPDFConfiguration()
            pcfg.rect = NSRect(x: 0, y: 0, width: 794, height: 1123)
            webView.createPDF(configuration: pcfg) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: self.output, options: .atomic)
                        exit(0)
                    } catch {
                        FileHandle.standardError.write("write error: \(error)\n".data(using: .utf8)!)
                        exit(1)
                    }
                case .failure(let error):
                    FileHandle.standardError.write("pdf error: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("load error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let loader = Loader(output: output)
loader.webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
app.run()
