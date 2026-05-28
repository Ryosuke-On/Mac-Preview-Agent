import Foundation
import AppKit

/// Wraps the `claude` CLI in stream-json mode as a long-lived subprocess.
/// Sends user messages on stdin (one JSON per line), parses stream events on stdout.
@MainActor
final class ClaudeAgent: ObservableObject {
    enum Event {
        case assistantText(String)         // streaming text delta from assistant
        case assistantTurnEnd               // assistant message complete
        case toolUse(name: String, input: String)
        case toolResult(String)
        case systemInfo(String)
        case error(String)
    }

    @Published var isRunning: Bool = false
    @Published var lastError: String?
    @Published private(set) var sessionId: String?
    /// Cumulative token usage and cost across all turns in this session.
    @Published private(set) var totalInputTokens: Int = 0
    @Published private(set) var totalOutputTokens: Int = 0
    @Published private(set) var totalCostUSD: Double = 0
    @Published private(set) var lastTurnInputTokens: Int = 0
    @Published private(set) var lastTurnOutputTokens: Int = 0

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    // Drip animation: queue received text chunks and emit character by character.
    private var dripQueue: [Character] = []
    private var dripTask: Task<Void, Never>?
    /// Chars per second for the drip animation. Matches roughly the Anthropic API's
    /// natural streaming speed (~400 chars/sec ≈ 100 tokens/sec).
    private let dripCharsPerSecond: Double = 400

    private let workingDir: URL
    private let initialContext: String
    private(set) var model: String
    private var resumeSessionId: String?
    /// Set when the open file is an image (PNG/JPEG/GIF/WebP/HEIC/TIFF/BMP).
    /// The image is attached to the user's first message so Claude can see it.
    private let imageURL: URL?
    private var hasSentImage = false
    var onEvent: ((Event) -> Void)?
    var onSessionId: ((String) -> Void)?

    init(fileURL: URL, model: String, resumeSessionId: String? = nil) {
        self.workingDir = fileURL.deletingLastPathComponent()
        self.model = model
        self.resumeSessionId = resumeSessionId
        self.sessionId = resumeSessionId
        let ext = fileURL.pathExtension.lowercased()
        let imageExts: Set<String> = ["png","jpg","jpeg","gif","webp","heic","heif","tiff","tif","bmp"]
        let isImage = imageExts.contains(ext)
        self.imageURL = isImage ? fileURL : nil
        let isPDF = ext == "pdf"
        let pdfRules: String = isPDF ? """

        PDF citation rules — IMPORTANT when answering about the PDF:
        - When a statement in your reply is supported by specific content in the PDF, append an inline citation marker immediately after that statement, using EXACTLY this format:
          [[cite:PAGE|VERBATIM_QUOTE]]
          where PAGE is the 1-based page number, and VERBATIM_QUOTE is a short (≤60 chars) literal phrase copied verbatim from that page. Do NOT paraphrase the quote — the UI searches for it in the PDF.
        - Place the marker on the same line as the supported sentence, after the punctuation.
        - You MAY use multiple citation markers per sentence if needed.
        - Do NOT invent citations: only add markers when you actually read content from the PDF that supports the claim.
        - Use citations primarily for factual claims, numbers, names, definitions, and quoted passages — not for trivial filler.
        - Example: 著者は X 法を提案している。[[cite:3|We propose method X]]
        """ : ""

        let webRules = """

        Web citation rules — when you use WebSearch or WebFetch to ground a claim:
        - You have access to WebSearch and WebFetch tools. Use them when the user's question requires information not in the open file (recent news, broader context, related papers, definitions outside the document).
        - When a statement in your reply is supported by a web source, append a marker immediately after that statement, using EXACTLY this format:
          [[web:URL|SHORT_LABEL]]
          where URL is the full https://... URL of the source, and SHORT_LABEL is a brief identifier ≤40 chars (site name, paper title, or author-year).
        - One marker per distinct source. Avoid duplicate markers for the same URL on the same sentence.
        - Do NOT invent URLs or labels. Only cite pages you actually retrieved via WebSearch/WebFetch.
        - Example: 最新のベンチマークでは X が SOTA を達成している。[[web:https://arxiv.org/abs/2401.12345|arXiv 2401.12345]]
        """

        let imageNote: String = isImage ? """

        IMPORTANT: This file is an image (\(fileURL.lastPathComponent)). The image itself
        is attached to the user's first message in this conversation — refer to it
        visually. Do NOT use the Read tool on the image file; it won't return useful
        content. Describe, analyze, OCR, or answer questions about what you see.
        """ : ""

        self.initialContext = """
        You are helping the user understand a specific file they are currently viewing.
        File path: \(fileURL.path)
        Working directory: \(fileURL.deletingLastPathComponent().path)
        When asked about "this file" or "the document", refer to that file.
        You can read other files in the working directory, run searches, and write markdown summary files when asked.\(imageNote)

        Formatting rules — VERY IMPORTANT, the UI renders your replies as Markdown:
        - Respond in the same language as the user.
        - Separate paragraphs with a blank line.
        - Use `## ` for section headings when the answer has multiple parts.
        - Use `- ` bullet lists for enumerations; never inline a list as a long sentence.
        - Use `**bold**` sparingly for key terms only, not whole sentences.
        - Use fenced code blocks ``` for code, formulas, and file paths longer than a few words.
        - Use inline `code` for short identifiers, file names, math symbols.
        - Keep paragraphs short (2–4 sentences max).\(pdfRules)\(webRules)
        """
    }

    func start() {
        guard process == nil else { return }
        let p = Process()
        let claudePath = findClaudeBinary()
        p.executableURL = URL(fileURLWithPath: claudePath)
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--append-system-prompt", initialContext,
            "--permission-mode", "acceptEdits",
            // Pre-approve web tools so Claude can search/fetch without per-call prompts
            // that our UI doesn't surface. File edits remain auto-approved via the mode.
            "--allowedTools", "WebSearch,WebFetch",
            "--model", model,
        ]
        if let resume = resumeSessionId {
            args.append(contentsOf: ["--resume", resume])
        }
        p.arguments = args
        p.currentDirectoryURL = workingDir
        // Build environment: start from the GUI process env, ensure PATH includes
        // common locations for `node` / `claude`, then layer optional user config.
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        env["FORCE_COLOR"] = "0"
        // Strip variables that might leak from a parent Claude Code session and
        // cause auth confusion. We want claude to use ~/.claude.json OAuth creds
        // (or our config file's API key) — not whatever happens to be in env.
        for k in ["CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                  "CLAUDE_CODE_EXECPATH", "CLAUDECODE",
                  "CLAUDE_AGENT_SDK_VERSION"] {
            env.removeValue(forKey: k)
        }
        if let cfg = loadUserConfig() {
            if let key = cfg.anthropicApiKey { env["ANTHROPIC_API_KEY"] = key }
            if let url = cfg.anthropicBaseUrl { env["ANTHROPIC_BASE_URL"] = url }
        }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.handleStdout(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.lastError = s
                    self?.onEvent?(.error(s))
                }
            }
        }

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }

        do {
            try p.run()
            self.process = p
            self.isRunning = true
            onEvent?(.systemInfo("Claude session started in \(workingDir.path)"))
        } catch {
            onEvent?(.error("Failed to launch claude: \(error.localizedDescription)"))
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Restart the underlying claude subprocess with a new model, preserving the
    /// session id so context is retained via `--resume`.
    func setModel(_ newModel: String) {
        guard newModel != model else { return }
        self.model = newModel
        self.resumeSessionId = sessionId
        stop()
        start()
    }

    /// Forget the current session; next start() spawns a fresh conversation.
    func resetSession() {
        cancelDrip()
        stop()
        self.resumeSessionId = nil
        self.sessionId = nil
        self.hasSentImage = false   // re-attach image on first message of new session
    }

    // MARK: - Drip animation

    /// Queue text to drip-feed character by character to the UI.
    private func enqueueDrip(_ text: String) {
        dripQueue.append(contentsOf: text)
        guard dripTask == nil || dripTask!.isCancelled else { return }
        dripTask = Task { [weak self] in
            await self?.runDrip()
        }
    }

    private func runDrip() async {
        // Batch delivery: drain up to N chars per frame at ~30fps.
        // This keeps the animation smooth without overwhelming the UI with 400 updates/sec.
        let frameNanos: UInt64 = 33_000_000            // ~30fps
        let charsPerFrame = max(1, Int(dripCharsPerSecond / 30))
        while !dripQueue.isEmpty {
            guard !Task.isCancelled else { break }
            let batch = String(dripQueue.prefix(charsPerFrame))
            dripQueue.removeFirst(min(charsPerFrame, dripQueue.count))
            onEvent?(.assistantText(batch))
            try? await Task.sleep(nanoseconds: frameNanos)
        }
        dripTask = nil
    }

    private func cancelDrip() {
        dripTask?.cancel()
        dripTask = nil
        dripQueue.removeAll()
    }

    /// Call after a full assistant turn ends: flush any remaining queued chars
    /// instantly then fire turnEnd.
    private func flushDripAndEnd() async {
        // Wait for drip to finish naturally (it's near the end of the text)
        if let t = dripTask {
            await t.value
        }
        onEvent?(.assistantTurnEnd)
    }

    func send(userMessage: String) {
        if process == nil { start() }
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }

        // Build the content. If this is the first user message in an image session,
        // attach the image as a base64 content block alongside the text.
        let content: Any
        if let imgURL = imageURL, !hasSentImage,
           let encoded = encodeImageForVision(imgURL) {
            content = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": encoded.mediaType,
                        "data": encoded.base64
                    ]
                ],
                ["type": "text", "text": userMessage]
            ] as [Any]
            hasSentImage = true
        } else {
            content = userMessage
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": content
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var line = data
        line.append(0x0A)  // newline
        try? stdin.write(contentsOf: line)
    }

    /// Encode an image at `url` as base64 + Anthropic-supported media_type. For HEIC,
    /// TIFF, BMP, etc. which Anthropic doesn't accept directly, re-encode as PNG.
    private func encodeImageForVision(_ url: URL) -> (mediaType: String, base64: String)? {
        let ext = url.pathExtension.lowercased()
        let direct: [String: String] = [
            "png": "image/png",
            "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
        ]
        if let media = direct[ext], let data = try? Data(contentsOf: url) {
            return (media, data.base64EncodedString())
        }
        // Fallback: load with NSImage and re-encode as PNG.
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:])
        else { return nil }
        return ("image/png", png.base64EncodedString())
    }

    /// Cancel the current in-flight assistant turn.
    /// Strategy: kill the subprocess immediately, then restart it with `--resume <sid>`
    /// so the session history (everything Claude has fully committed) is preserved.
    /// This is more reliable than control_request interrupts which the CLI version
    /// may or may not honor, and it gives instant feedback to the user.
    func cancelTurn() {
        // Stop the drip animation immediately for UI responsiveness.
        cancelDrip()
        // Persist the session id for resume.
        let sid = sessionId
        // Kill the subprocess. The terminationHandler will clear isRunning.
        process?.terminate()
        process = nil
        isRunning = false
        // Emit turn end so the UI flips the streaming flag off.
        onEvent?(.assistantTurnEnd)
        // Restart with resume so next user message continues the conversation.
        if let sid {
            self.resumeSessionId = sid
            start()
        }
    }

    // MARK: - stdout parsing

    private func handleStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            if lineData.isEmpty { continue }
            parseEventLine(lineData)
        }
    }

    private func parseEventLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }

        switch type {
        case "system":
            if let sub = obj["subtype"] as? String, sub == "init" {
                if let sid = obj["session_id"] as? String {
                    self.sessionId = sid
                    onSessionId?(sid)
                }
                onEvent?(.systemInfo("ready"))
            }
        case "assistant":
            if let msg = obj["message"] as? [String: Any] {
                // Pull per-message usage (Anthropic API includes it on every assistant message).
                if let usage = msg["usage"] as? [String: Any] {
                    applyUsage(usage)
                }
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content {
                        if let btype = block["type"] as? String {
                            if btype == "text", let t = block["text"] as? String {
                                enqueueDrip(t)
                            } else if btype == "tool_use" {
                                let name = block["name"] as? String ?? "tool"
                                let inputStr: String
                                if let input = block["input"] {
                                    let d = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted])
                                    inputStr = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                                } else { inputStr = "" }
                                onEvent?(.toolUse(name: name, input: inputStr))
                            }
                        }
                    }
                    Task { await self.flushDripAndEnd() }
                }
            }
        case "user":
            // tool_result echoed back as user message containing tool_result blocks
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_result" {
                        let c = block["content"]
                        let s: String
                        if let str = c as? String { s = str }
                        else if let arr = c as? [[String: Any]] {
                            s = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        } else { s = "" }
                        onEvent?(.toolResult(s))
                    }
                }
            }
        case "result":
            if let usage = obj["usage"] as? [String: Any] { applyUsage(usage) }
            if let cost = obj["total_cost_usd"] as? Double {
                // total_cost_usd is reported cumulatively for the session.
                totalCostUSD = max(totalCostUSD, cost)
            } else if let cost = obj["cost_usd"] as? Double {
                totalCostUSD += cost
            }
            if (obj["is_error"] as? Bool) == true,
               let msg = obj["result"] as? String {
                let lower = msg.lowercased()
                if lower.contains("not logged in") || lower.contains("authentication") || lower.contains("401") {
                    onEvent?(.error("認証されていません。ターミナルで `claude /login` を一度実行するか、 ~/.config/previewchat/config.json に `{\"anthropicApiKey\": \"sk-ant-...\"}` を置いてください。"))
                } else {
                    onEvent?(.error(msg))
                }
            }
        default:
            break
        }
    }

    /// Add tokens from a usage dict to running totals. Per-message usage from streaming
    /// reflects *this message's* usage, so we add (not overwrite).
    private func applyUsage(_ usage: [String: Any]) {
        let inT = (usage["input_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let outT = (usage["output_tokens"] as? Int) ?? 0
        let totalIn = inT + cacheCreate + cacheRead
        guard totalIn > 0 || outT > 0 else { return }
        lastTurnInputTokens = totalIn
        lastTurnOutputTokens = outT
        totalInputTokens += totalIn
        totalOutputTokens += outT
    }

    private struct UserConfig: Decodable {
        let anthropicApiKey: String?
        let anthropicBaseUrl: String?
    }

    private func loadUserConfig() -> UserConfig? {
        let path = "\(NSHomeDirectory())/.config/previewchat/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(UserConfig.self, from: data)
    }

    private func findClaudeBinary() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Last resort: rely on PATH lookup via /usr/bin/env
        return "/usr/bin/env"
    }
}
