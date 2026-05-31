import Foundation
import AppKit
import CryptoKit
import PDFKit

enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Wraps a local agent CLI and normalizes its events for the chat UI.
/// Claude runs as a long-lived stream-json subprocess; Codex runs one JSONL
/// `codex exec` turn at a time and resumes via the persisted thread id.
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
    private let codexFileContext: String
    private let codexAdditionalReadDir: URL?
    private(set) var agentKind: AgentKind
    private(set) var model: String
    private var resumeSessionId: String?
    /// Set when the open file is an image (PNG/JPEG/GIF/WebP/HEIC/TIFF/BMP).
    /// The image is attached to the user's first message so Claude can see it.
    private let imageURL: URL?
    private var hasSentImage = false
    var onEvent: ((Event) -> Void)?
    var onSessionId: ((String) -> Void)?

    init(fileURL: URL, agentKind: AgentKind, model: String, resumeSessionId: String? = nil) {
        self.workingDir = fileURL.deletingLastPathComponent()
        self.agentKind = agentKind
        self.model = model
        self.resumeSessionId = resumeSessionId
        self.sessionId = resumeSessionId
        let ext = fileURL.pathExtension.lowercased()
        let imageExts: Set<String> = ["png","jpg","jpeg","gif","webp","heic","heif","tiff","tif","bmp"]
        let isImage = imageExts.contains(ext)
        self.imageURL = isImage ? fileURL : nil
        let isPDF = ext == "pdf"
        let codexPDFContext = isPDF ? Self.preparePDFTextContext(from: fileURL) : .empty
        self.codexFileContext = codexPDFContext.prompt
        self.codexAdditionalReadDir = codexPDFContext.readableDir
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

        // Only Claude is launched with WebSearch/WebFetch enabled. `codex exec` has no
        // web tools by default, so don't promise a capability it can't deliver.
        let webRules = agentKind == .claude ? """

        Web citation rules — when you use web search or fetch tools to ground a claim:
        - Use web tools when your runtime provides them and the user's question requires information not in the open file (recent news, broader context, related papers, definitions outside the document).
        - When a statement in your reply is supported by a web source, append a marker immediately after that statement, using EXACTLY this format:
          [[web:URL|SHORT_LABEL]]
          where URL is the full https://... URL of the source, and SHORT_LABEL is a brief identifier ≤40 chars (site name, paper title, or author-year).
        - One marker per distinct source. Avoid duplicate markers for the same URL on the same sentence.
        - Do NOT invent URLs or labels. Only cite pages you actually retrieved via WebSearch/WebFetch.
        - Example: 最新のベンチマークでは X が SOTA を達成している。[[web:https://arxiv.org/abs/2401.12345|arXiv 2401.12345]]
        """ : ""

        let imageNote: String = isImage ? """

        IMPORTANT: This file is an image (\(fileURL.lastPathComponent)). The image itself
        is attached to the user's first message in this conversation when the active
        agent supports image attachments — refer to it visually. Do NOT use a text
        file reader on the image; it won't return useful content. Describe, analyze,
        OCR, or answer questions about what you see.
        """ : ""

        let pdfNote: String = isPDF ? """

        IMPORTANT: This file is a PDF (\(fileURL.lastPathComponent)). For Codex sessions,
        PreviewAgent provides page-by-page extracted text directly in the initial prompt.
        It also creates a page cache for page-specific follow-up reads. Use those supplied
        sources first. Do not spend time looking for `pdftotext` or Python PDF libraries
        unless the supplied text/cache is clearly missing the needed content.
        """ : ""

        self.initialContext = """
        You are helping the user understand a specific file they are currently viewing.
        File path: \(fileURL.path)
        Working directory: \(fileURL.deletingLastPathComponent().path)
        When asked about "this file" or "the document", refer to that file.
        You can read other files in the working directory, run searches, and write markdown summary files when asked.\(imageNote)\(pdfNote)

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
        guard agentKind == .claude else {
            // For Codex there is no long-lived process: `isRunning` simply reflects
            // whether the agent is available/active (mirrors Claude's green status dot).
            if resolveCodexBinary() != nil {
                isRunning = true
                onEvent?(.systemInfo("Codex ready in \(workingDir.path)"))
            } else {
                isRunning = false
                onEvent?(.error("codex が見つかりません。Codex.app をインストールするか、`codex` を PATH に追加してください。"))
            }
            return
        }
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
            // Pre-approve the read/search/web tools so Claude can inspect the open file
            // (Read handles PDFs & images natively), browse the working directory, and
            // search the web without per-call permission prompts that our UI doesn't
            // surface. File edits remain auto-approved via the permission mode.
            "--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch",
        ]
        args.append(contentsOf: ["--model", model])
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

        p.terminationHandler = { [weak self, weak p] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only react if THIS process is still the active one. When the
                // subprocess is restarted (setModel / cancelTurn call stop()+start()
                // synchronously on the main actor), the old process terminates and
                // this handler runs afterward — it must NOT clobber the freshly
                // started process reference or flip isRunning off.
                guard self.process === p else { return }
                self.isRunning = false
                self.process = nil
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

    /// Restart the underlying subprocess with a new backend/model. Claude can preserve
    /// context with `--resume`; Codex keeps the thread id and resumes on the next turn.
    func setModel(_ newModel: String) {
        guard newModel != model else { return }
        self.model = newModel
        self.resumeSessionId = sessionId
        stop()
        start()
    }

    func setAgent(kind newKind: AgentKind, model newModel: String) {
        guard newKind != agentKind || newModel != model else { return }
        cancelDrip()
        stop()
        self.agentKind = newKind
        self.model = newModel
        self.resumeSessionId = nil
        self.sessionId = nil
        self.hasSentImage = false
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
        if agentKind == .codex {
            sendCodex(userMessage: userMessage)
            return
        }
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
        if agentKind == .claude, let sid {
            self.resumeSessionId = sid
            start()
        } else if agentKind == .codex {
            isRunning = true
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
        if agentKind == .codex {
            parseCodexEvent(obj)
            return
        }
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
                onEvent?(.error(friendlyAgentError(msg)))
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
        let cacheRead = (usage["cache_read_input_tokens"] as? Int)
            ?? (usage["cached_input_tokens"] as? Int)
            ?? 0
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
        // Prefer the current path; fall back to the pre-rename location so existing
        // PreviewChat users keep their API key without re-creating the file.
        let paths = [
            "\(NSHomeDirectory())/.config/previewagent/config.json",
            "\(NSHomeDirectory())/.config/previewchat/config.json",
        ]
        for path in paths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let cfg = try? JSONDecoder().decode(UserConfig.self, from: data) {
                return cfg
            }
        }
        return nil
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

    // MARK: - Codex

    private func sendCodex(userMessage: String) {
        cancelDrip()
        lastTurnInputTokens = 0
        lastTurnOutputTokens = 0

        let p = Process()
        p.executableURL = URL(fileURLWithPath: findCodexBinary())
        p.arguments = codexArguments()
        p.currentDirectoryURL = workingDir
        p.environment = agentEnvironment()

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

        p.terminationHandler = { [weak self, weak p] proc in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.isRunning = true
                self.process = nil
                if proc.terminationStatus != 0 {
                    let msg = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = msg.isEmpty ? "Codex exited with status \(proc.terminationStatus)" : msg
                    self.onEvent?(.error(self.friendlyAgentError(text)))
                    self.onEvent?(.assistantTurnEnd)
                }
            }
        }

        do {
            try p.run()
            self.process = p
            self.isRunning = true
            let prompt = codexPrompt(for: userMessage)
            if let data = prompt.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()
        } catch {
            self.isRunning = false
            onEvent?(.error("Failed to launch codex: \(error.localizedDescription)"))
            onEvent?(.assistantTurnEnd)
        }
    }

    private func codexArguments() -> [String] {
        var args: [String] = ["exec"]
        let sid = sessionId ?? resumeSessionId
        if sid != nil { args.append("resume") }
        args.append(contentsOf: ["--json", "--skip-git-repo-check"])
        // `codex exec resume` rejects --sandbox/--color/--add-dir, so drive the sandbox
        // through a `-c` config override that is valid on BOTH the initial and resume
        // invocations. This keeps write capability symmetric across turns.
        args.append(contentsOf: ["-c", "sandbox_mode=\"workspace-write\""])
        if sid == nil {
            // --add-dir is only accepted on the first `exec`. It grants Codex *write*
            // access to the PDF page cache; reads of that temp dir are allowed on later
            // turns regardless, so resume does not need it re-added.
            if let dir = codexAdditionalReadDir {
                args.append(contentsOf: ["--add-dir", dir.path])
            }
        }
        if let cliModel = codexCLIModel {
            args.append(contentsOf: ["--model", cliModel])
        }
        if let img = imageURL, !hasSentImage {
            args.append(contentsOf: ["--image", img.path])
            hasSentImage = true
        }
        if let sid { args.append(sid) }
        args.append("-")
        return args
    }

    private var codexCLIModel: String? {
        model == "codex-default" ? nil : model
    }

    private func codexPrompt(for userMessage: String) -> String {
        guard sessionId == nil && resumeSessionId == nil else { return userMessage }
        return """
        \(initialContext)
        \(codexFileContext)

        User message:
        \(userMessage)
        """
    }

    private struct CodexPreparedFileContext {
        let prompt: String
        let readableDir: URL?

        static let empty = CodexPreparedFileContext(prompt: "", readableDir: nil)
    }

    private static func preparePDFTextContext(from url: URL) -> CodexPreparedFileContext {
        guard let doc = PDFDocument(url: url) else { return .empty }
        let maxCharacters = 120_000
        let cacheDir = pdfTextCacheDir(for: url)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var pageFiles: [String] = []
        var result = """

        PDF text supplied by PreviewAgent for Codex:
        - Page markers use this exact format: <page N>.
        - Use this text as the primary source for PDF questions.
        - When citing, use [[cite:PAGE|VERBATIM_QUOTE]] with a short literal phrase from the relevant page.
        - Full page cache directory for page-specific reads:
          \(cacheDir.path)
        - To inspect a specific page later, read:
          \(cacheDir.path)/page-0001.txt
          replacing 0001 with the 4-digit page number.
        - For a page range, read the corresponding page-XXXX.txt files from that cache directory.

        """
        var used = result.count
        var truncated = false

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pageNumber = i + 1
            let pageFileName = String(format: "page-%04d.txt", pageNumber)
            let pageFile = cacheDir.appendingPathComponent(pageFileName)
            let pageFileText = """
            <page \(pageNumber)>
            \(text)
            </page \(pageNumber)>

            """
            try? pageFileText.write(to: pageFile, atomically: true, encoding: .utf8)
            pageFiles.append(pageFileName)

            let block = """

            <page \(pageNumber)>
            \(text)
            </page \(pageNumber)>
            """
            if used + block.count > maxCharacters {
                truncated = true
                continue
            }
            result += block
            used += block.count
        }

        if truncated {
            result += """

            [PreviewAgent note: Inline PDF text was truncated because it is long. For pages not included inline, read the corresponding page-XXXX.txt file from the cache directory above before answering.]
            """
        }

        let indexText = """
        PDF page text cache
        Source: \(url.path)
        Page count: \(doc.pageCount)
        Files:
        \(pageFiles.joined(separator: "\n"))
        """
        try? indexText.write(to: cacheDir.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)

        return CodexPreparedFileContext(prompt: result, readableDir: cacheDir)
    }

    private static func pdfTextCacheDir(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let safeName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(40)
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("previewagent-pdf-cache", isDirectory: true)
            .appendingPathComponent("\(safeName)-\(hex)", isDirectory: true)
    }

    private func parseCodexEvent(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "thread.started":
            if let sid = obj["thread_id"] as? String {
                self.sessionId = sid
                self.resumeSessionId = sid
                onSessionId?(sid)
            }
        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return }
            emitCodexItem(type: itemType, item: item)
        case "turn.completed":
            if let usage = obj["usage"] as? [String: Any] { applyUsage(usage) }
            Task { await self.flushDripAndEnd() }
        case "turn.failed":
            let raw = ((obj["error"] as? [String: Any])?["message"] as? String)
                ?? (obj["message"] as? String)
                ?? "Codex turn failed"
            onEvent?(.error(friendlyAgentError(raw)))
            onEvent?(.assistantTurnEnd)
        default:
            break
        }
    }

    /// Normalize a Codex `item.completed` item into a tool-use chip for the UI.
    /// Codex emits richer item types than Claude's single `tool_use`; map the common
    /// ones (shell, edits, web search, MCP calls) so they're visible like Claude's.
    private func emitCodexItem(type: String, item: [String: Any]) {
        switch type {
        case "agent_message":
            if let text = item["text"] as? String { enqueueDrip(text) }
        case "command_execution":
            let cmd = (item["command"] as? String)
                ?? (item["aggregated_command"] as? String)
                ?? (item["parsed_cmd"] as? String) ?? ""
            emitToolUse(name: "Bash", json: ["command": cmd])
        case "file_change", "patch_apply":
            let path = (item["path"] as? String)
                ?? ((item["changes"] as? [[String: Any]])?.first?["path"] as? String)
                ?? ((item["files"] as? [String])?.first) ?? ""
            emitToolUse(name: "Edit", json: ["file_path": path])
        case "web_search":
            let query = (item["query"] as? String) ?? (item["text"] as? String) ?? ""
            emitToolUse(name: "WebSearch", json: ["query": query])
        case "mcp_tool_call":
            let server = (item["server"] as? String) ?? ""
            let tool = (item["tool"] as? String) ?? (item["name"] as? String) ?? "tool"
            let name = server.isEmpty ? tool : "\(server).\(tool)"
            onEvent?(.toolUse(name: name, input: (item["arguments"] as? String) ?? ""))
        case "tool_call":
            let name = (item["name"] as? String) ?? (item["tool_name"] as? String) ?? "tool"
            let input = (item["input"] as? String) ?? (item["arguments"] as? String) ?? ""
            onEvent?(.toolUse(name: name, input: input))
        case "error":
            let raw = (item["message"] as? String) ?? "Codex error"
            onEvent?(.error(friendlyAgentError(raw)))
        default:
            // reasoning, todo_list, etc. — not surfaced as chips.
            break
        }
    }

    private func emitToolUse(name: String, json: [String: Any]) {
        let str = (try? JSONSerialization.data(withJSONObject: json))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onEvent?(.toolUse(name: name, input: str))
    }

    /// Translate raw auth-style errors from either agent into an actionable message.
    private func friendlyAgentError(_ raw: String) -> String {
        let lower = raw.lowercased()
        let authish = lower.contains("not logged in") || lower.contains("authentication")
            || lower.contains("unauthorized") || lower.contains("401")
            || (lower.contains("login") && lower.contains("codex"))
        guard authish else { return raw }
        switch agentKind {
        case .claude:
            return "認証されていません。ターミナルで `claude /login` を一度実行するか、 ~/.config/previewagent/config.json に `{\"anthropicApiKey\": \"sk-ant-...\"}` を置いてください。"
        case .codex:
            return "Codex が認証されていません。ターミナルで `codex login` を一度実行してください。"
        }
    }

    /// Return the first existing Codex executable, or nil if none is installed.
    private func resolveCodexBinary() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Fall back to scanning PATH for a `codex` executable.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func findCodexBinary() -> String {
        resolveCodexBinary() ?? "/usr/bin/env"
    }

    private func agentEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        env["FORCE_COLOR"] = "0"
        return env
    }
}
