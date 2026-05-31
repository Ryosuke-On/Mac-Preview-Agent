import SwiftUI
import AppKit

// MARK: - CMD+F monitor for the chat pane

/// Intercepts the system CMD+F key event when the mouse is over the chat area,
/// firing `onFind`. When the mouse is elsewhere (e.g. over the PDF viewer),
/// passes the event through so PDFView can handle it natively.
final class ChatCmdFMonitor: ObservableObject {
    var isHovered = false
    var onFind: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 3 == 'f'
            guard event.keyCode == 3,
                  event.modifierFlags
                      .intersection(.deviceIndependentFlagsMask) == .command
            else { return event }
            if self?.isHovered == true {
                DispatchQueue.main.async { self?.onFind?() }
            } else {
                // Hover is on the viewer pane → fire find in PDF / Markdown viewer.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pcFind, object: nil)
                }
            }
            return nil   // always consumed so the system doesn't beep
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }
}

// MARK: - Data types

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool, system }
    let id = UUID()
    var role: Role
    var text: String
    var toolName: String? = nil
    var isStreaming: Bool = false
    /// Per-message token counts (assistant only, set when the turn ends).
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
}

enum ModelChoice: String, CaseIterable, Identifiable {
    // Use the CLI's version-agnostic aliases (not pinned `claude-…-4-x` names) so the
    // picker keeps working when Anthropic ships a new model version — `claude --model
    // sonnet` always resolves to the latest Sonnet. Codex's `gpt-5*` names are already
    // rolling aliases on OpenAI's side, and "Default" omits --model entirely.
    case claudeHaiku  = "haiku"
    case claudeSonnet = "sonnet"
    case claudeOpus   = "opus"
    case codexDefault = "codex-default"
    case gpt5Codex    = "gpt-5-codex"
    case gpt5         = "gpt-5"

    var id: String { rawValue }

    var agentKind: AgentKind {
        switch self {
        case .claudeHaiku, .claudeSonnet, .claudeOpus: .claude
        case .codexDefault, .gpt5Codex, .gpt5: .codex
        }
    }

    var label: String {
        switch self {
        case .claudeHaiku: "Haiku"
        case .claudeSonnet: "Sonnet"
        case .claudeOpus: "Opus"
        case .codexDefault: "Default"
        case .gpt5Codex: "GPT-5 Codex"
        case .gpt5: "GPT-5"
        }
    }

    static func choices(for agentKind: AgentKind) -> [ModelChoice] {
        allCases.filter { $0.agentKind == agentKind }
    }

    static func fallback(for agentKind: AgentKind) -> ModelChoice {
        switch agentKind {
        case .claude: .claudeSonnet
        case .codex: .codexDefault
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    let fileURL: URL
    var onHide: (() -> Void)? = nil   // called when the user clicks the hide button
    @StateObject private var agent: ClaudeAgent
    @StateObject private var cmdFMonitor = ChatCmdFMonitor()
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingIndex: Int? = nil
    @AppStorage("preferredAgent") private var preferredAgentRaw: String = AgentKind.claude.rawValue
    @AppStorage("preferredClaudeModel") private var preferredClaudeModelRaw: String = ModelChoice.claudeSonnet.rawValue
    @AppStorage("preferredCodexModel") private var preferredCodexModelRaw: String = ModelChoice.codexDefault.rawValue
    @State private var showClearConfirm = false

    // Chat search state
    @State private var isSearchVisible = false
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool

    init(fileURL: URL, onHide: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.onHide = onHide
        let saved = ChatStore.load(for: fileURL)
        let savedAgent = saved?.agentKind.flatMap(AgentKind.init(rawValue:))
        let agentKind = savedAgent
            ?? AgentKind(rawValue: UserDefaults.standard.string(forKey: "preferredAgent") ?? "")
            ?? .claude
        let modelKey: String
        switch agentKind {
        case .claude: modelKey = "preferredClaudeModel"
        case .codex: modelKey = "preferredCodexModel"
        }
        let fallback = ModelChoice.fallback(for: agentKind)
        // Discard any stale/legacy stored value (e.g. a previously pinned
        // "claude-sonnet-4-6") that no longer maps to a known choice for this agent.
        let storedModel = UserDefaults.standard.string(forKey: modelKey)
            .flatMap(ModelChoice.init(rawValue:))
            .flatMap { $0.agentKind == agentKind ? $0 : nil }
        let model = (storedModel ?? fallback).rawValue
        _agent = StateObject(wrappedValue: ClaudeAgent(
            fileURL: fileURL,
            agentKind: agentKind,
            model: model,
            resumeSessionId: saved?.sessionId
        ))
    }

    // Active highlight query (empty when search is hidden or empty).
    private var activeQuery: String {
        (isSearchVisible && !searchQuery.isEmpty) ? searchQuery : ""
    }

    // Total occurrence count across all messages (case-insensitive).
    private var totalMatches: Int {
        let q = activeQuery
        guard !q.isEmpty else { return 0 }
        return messages.reduce(0) { $0 + $1.text.occurrences(of: q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            usageBar
            Divider()
            if isSearchVisible { searchBar }
            ScrollViewReader { proxy in
                ScrollView {
                    // VStack (not Lazy) avoids the blank-frame flash that LazyVStack
                    // produces when new items are inserted and scrolled into view.
                    VStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                        }
                        ForEach(messages) { msg in
                            MessageRow(
                                message: msg,
                                highlight: activeQuery,
                                isStreaming: streamingIndex != nil,
                                onEdit: msg.role == .user && streamingIndex == nil
                                    ? { editMessage(id: msg.id) } : nil,
                                onRegenerate: msg.role == .assistant && streamingIndex == nil
                                    ? { regenerate(id: msg.id) } : nil
                            )
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                // Single scroll handler — no animation during streaming to prevent flicker.
                .onChange(of: messages) { _, _ in
                    // Don't auto-scroll while searching so the user can browse matches.
                    guard activeQuery.isEmpty else { return }
                    if streamingIndex != nil {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            inputBar
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        // Track hover so CMD+F monitor knows when to intercept.
        .onHover { cmdFMonitor.isHovered = $0 }
        .onAppear {
            if let saved = ChatStore.load(for: fileURL) {
                messages = saved.messages.map {
                    ChatMessage(role: .init(rawValue: $0.role) ?? .system,
                                text: $0.text, toolName: $0.toolName,
                                inputTokens: $0.inputTokens,
                                outputTokens: $0.outputTokens)
                }
                if let savedKind = saved.agentKind, let kind = AgentKind(rawValue: savedKind) {
                    preferredAgentRaw = kind.rawValue
                }
            }
            agent.onEvent = { handleEvent($0) }
            agent.onSessionId = { _ in persist() }
            agent.start()
            cmdFMonitor.onFind = { showSearch() }
            cmdFMonitor.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pcAskAboutSelection)) { note in
            guard let info = note.userInfo,
                  let text = info["text"] as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Collapse internal whitespace runs (PDF text often has weird breaks).
            let cleaned = trimmed
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let pageNote: String
            if let page = info["page"] as? Int { pageNote = " (p.\(page))" } else { pageNote = "" }
            // Format requested by the user:
            //   以下の引用
            //   > <selected text> (p.N)について、
            // The user types their question after について、.
            let prefill = "以下の引用\n> \(cleaned)\(pageNote)について、"
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                input = prefill
            } else {
                input = prefill + "\n\n" + input
            }
            // Ask the input field to focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .pcFocusChatInput, object: nil)
            }
        }
        .onDisappear {
            persist()
            agent.stop()
            cmdFMonitor.stop()
        }
        .confirmationDialog("チャット履歴を消去しますか？", isPresented: $showClearConfirm) {
            Button("消去", role: .destructive) { clearHistory() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このファイルに紐づく会話とエージェントセッションを削除します。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
            Picker("", selection: Binding(
                get: { selectedAgent },
                set: { setAgent($0) }
            )) {
                ForEach(AgentKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 84)
            Picker("", selection: Binding(
                get: { selectedModel },
                set: { setModel($0) }
            )) {
                ForEach(ModelChoice.choices(for: selectedAgent)) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 116)
            Spacer(minLength: 0)
            Button { showClearConfirm = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("チャット履歴を消去")
            if let onHide {
                Button { onHide() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).help("チャットを隠す (⌘\\)")
            }
            Circle().fill(agent.isRunning ? Color.green : Color.gray).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private var selectedAgent: AgentKind {
        AgentKind(rawValue: preferredAgentRaw) ?? .claude
    }

    private var selectedModel: ModelChoice {
        let raw: String
        switch selectedAgent {
        case .claude: raw = preferredClaudeModelRaw
        case .codex: raw = preferredCodexModelRaw
        }
        let choice = ModelChoice(rawValue: raw) ?? ModelChoice.fallback(for: selectedAgent)
        return choice.agentKind == selectedAgent ? choice : ModelChoice.fallback(for: selectedAgent)
    }

    private func setAgent(_ kind: AgentKind) {
        preferredAgentRaw = kind.rawValue
        let model = selectedModel
        agent.setAgent(kind: kind, model: model.rawValue)
        streamingIndex = nil
        persist()
    }

    private func setModel(_ model: ModelChoice) {
        if model.agentKind == .claude {
            preferredClaudeModelRaw = model.rawValue
        } else {
            preferredCodexModelRaw = model.rawValue
        }
        agent.setModel(model.rawValue)
        persist()
    }

    /// Session-cumulative token counter shown just under the header.
    private var usageBar: some View {
        Group {
            if agent.totalInputTokens > 0 || agent.totalOutputTokens > 0 {
                HStack(spacing: 6) {
                    Text("累計").foregroundStyle(.quaternary)
                    Image(systemName: "arrow.up").font(.system(size: 9))
                    Text(formatTokens(agent.totalInputTokens)).monospacedDigit()
                    Image(systemName: "arrow.down").font(.system(size: 9))
                    Text(formatTokens(agent.totalOutputTokens)).monospacedDigit()
                    if agent.totalCostUSD > 0 {
                        Text(String(format: "$%.4f", agent.totalCostUSD)).monospacedDigit()
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .help("このセッションの累計: 入力 \(agent.totalInputTokens) tok / 出力 \(agent.totalOutputTokens) tok" + (agent.totalCostUSD > 0 ? String(format: " / $%.4f", agent.totalCostUSD) : ""))
            }
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("このファイルについて質問できます。").font(.subheadline).foregroundStyle(.secondary)
            Text("Enter で送信 / Shift+Enter で改行").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 20)
    }


    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.subheadline)
            TextField("チャット内を検索", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($searchFieldFocused)
                .onExitCommand { dismissSearch() }
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Text(searchQuery.isEmpty ? "" : "\(totalMatches) 件")
                .font(.caption).foregroundStyle(.tertiary).frame(minWidth: 36, alignment: .trailing)
            Button("完了") { dismissSearch() }
                .buttonStyle(.borderless).font(.subheadline)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatInputField(text: $input, onSubmit: send)
                .frame(minHeight: 38, maxHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            if streamingIndex != nil {
                Button(action: stopStreaming) {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("生成を停止 (⌘.)")
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: send) { Image(systemName: "paperplane.fill").frame(width: 28, height: 28) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func stopStreaming() {
        guard let i = streamingIndex, messages.indices.contains(i) else {
            agent.cancelTurn(); return
        }
        // Find the user message that triggered this turn so we can restore it to the
        // input field — the user likely wants to edit/refine and resend.
        let userText = messages[..<i].last(where: { $0.role == .user })?.text
        // Mark partial assistant message as stopped (preserve what was generated so far).
        if messages[i].text.isEmpty {
            messages.remove(at: i)
        } else {
            messages[i].isStreaming = false
            messages[i].text += "\n\n_（停止しました）_"
        }
        streamingIndex = nil
        agent.cancelTurn()
        persist()
        // Restore the user's original message into the input box.
        if let t = userText {
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                input = t
            } else {
                input = t + "\n\n" + input
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .pcFocusChatInput, object: nil)
            }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        agent.send(userMessage: text)
        persist()
    }

    private func editMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .user else { return }
        let text = messages[idx].text
        messages.removeSubrange(idx...)
        agent.resetSession()
        agent.start()
        input = text
        persist()
    }

    private func regenerate(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .assistant else { return }
        guard let userText = messages[0..<idx].last(where: { $0.role == .user })?.text else { return }
        messages.removeSubrange(idx...)
        agent.resetSession()
        agent.start()
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        agent.send(userMessage: userText)
        persist()
    }

    private func clearHistory() {
        messages.removeAll()
        streamingIndex = nil
        ChatStore.clear(for: fileURL)
        agent.resetSession()
        agent.start()
    }

    private func showSearch() {
        withAnimation(.easeOut(duration: 0.15)) { isSearchVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFieldFocused = true }
    }

    private func dismissSearch() {
        withAnimation(.easeOut(duration: 0.15)) { isSearchVisible = false }
        searchQuery = ""
        searchFieldFocused = false
    }

    // MARK: - Event handling

    private func handleEvent(_ event: ClaudeAgent.Event) {
        switch event {
        case .assistantText(let t):
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text += t
            } else {
                messages.append(ChatMessage(role: .assistant, text: t, isStreaming: true))
                streamingIndex = messages.count - 1
            }
        case .assistantTurnEnd:
            if let i = streamingIndex, messages.indices.contains(i) {
                if messages[i].text.isEmpty { messages.remove(at: i) }
                else {
                    messages[i].isStreaming = false
                    // Snapshot this turn's token counts onto the message.
                    if agent.lastTurnInputTokens > 0 || agent.lastTurnOutputTokens > 0 {
                        messages[i].inputTokens = agent.lastTurnInputTokens
                        messages[i].outputTokens = agent.lastTurnOutputTokens
                    }
                }
            }
            streamingIndex = nil
            persist()
        case .toolUse(let name, let input):
            messages.append(ChatMessage(role: .tool,
                                        text: summarize(toolName: name, input: input),
                                        toolName: name))
            streamingIndex = nil
        case .toolResult: break
        case .systemInfo: break
        case .error(let e):
            messages.append(ChatMessage(role: .system, text: "⚠️ \(e)"))
            persist()
        }
    }

    private func persist() {
        ChatStore.save(.init(
            messages: messages.map {
                .init(role: $0.role.rawValue, text: $0.text, toolName: $0.toolName,
                      inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
            },
            sessionId: agent.sessionId
            ,
            agentKind: agent.agentKind.rawValue
        ), for: fileURL)
    }

    private func summarize(toolName: String, input: String) -> String {
        if let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch toolName {
            case "Read":  if let p = obj["file_path"] as? String { return "Read \(p)" }
            case "Write": if let p = obj["file_path"] as? String { return "Write \(p)" }
            case "Edit":  if let p = obj["file_path"] as? String { return "Edit \(p)" }
            case "Grep":  if let p = obj["pattern"]   as? String { return "Grep \(p)" }
            case "Glob":  if let p = obj["pattern"]   as? String { return "Glob \(p)" }
            case "Bash":  if let c = obj["command"]   as? String { return "Bash $ \(c)" }
            case "WebSearch": if let q = obj["query"] as? String { return "WebSearch \(q)" }
            case "WebFetch":  if let u = obj["url"]   as? String { return "WebFetch \(u)" }
            default: break
            }
        }
        return toolName
    }
}

// MARK: - Chat input

struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        context.coordinator.textView = tv
        context.coordinator.installFocusObserver()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ChatInputField
        weak var textView: NSTextView?
        private var focusObserver: NSObjectProtocol?
        init(_ p: ChatInputField) { self.parent = p }
        func textDidChange(_ n: Notification) {
            (n.object as? NSTextView).map { parent.text = $0.string }
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) { tv.insertNewlineIgnoringFieldEditor(nil) }
            else { parent.onSubmit() }
            return true
        }
        func installFocusObserver() {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .pcFocusChatInput, object: nil, queue: .main
            ) { [weak self] _ in
                guard let tv = self?.textView else { return }
                tv.window?.makeFirstResponder(tv)
                // Place cursor at end so user can type their question right away.
                let end = (tv.string as NSString).length
                tv.selectedRange = NSRange(location: end, length: 0)
            }
        }
        deinit {
            if let o = focusObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    var highlight: String = ""
    var isStreaming: Bool = false   // true when ANY message is streaming
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @State private var hovering = false
    // Height reported back from WKWebView-based markdown renderer.
    @State private var webHeight: CGFloat = 60

    var body: some View {
        switch message.role {
        case .user:
            // Entire VStack (bubble + action bar) is the hover zone.
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 30)
                    Text(message.text.highlighted(query: highlight))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.15)))
                }
                // Action bar — always in layout, opacity drives visibility.
                HStack(spacing: 6) {
                    Spacer()
                    actionButton(icon: "doc.on.doc", label: "コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    if let onEdit {
                        actionButton(icon: "pencil", label: "編集して再送信", action: onEdit)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())   // full-width hover target
            .onHover { hovering = $0 }

        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint).frame(width: 16).padding(.top, 2)
                    renderedAssistant
                    Spacer(minLength: 0)
                }
                // Action bar + per-turn tokens
                if !message.isStreaming {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 24)   // align under content
                        actionButton(icon: "doc.on.doc", label: "コピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        if let onRegenerate {
                            actionButton(icon: "arrow.clockwise", label: "再生成", action: onRegenerate)
                        }
                        // Per-message tokens (always visible, very subtle).
                        if let inT = message.inputTokens, let outT = message.outputTokens,
                           inT > 0 || outT > 0 {
                            Spacer().frame(width: 4)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up").font(.system(size: 8))
                                Text(formatTokenCount(inT)).monospacedDigit()
                                Image(systemName: "arrow.down").font(.system(size: 8))
                                Text(formatTokenCount(outT)).monospacedDigit()
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("このメッセージ: 入力 \(inT) tok / 出力 \(outT) tok")
                        }
                        Spacer()
                    }
                    .opacity(hovering ? 1 : (message.inputTokens != nil ? 0.55 : 0))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }

        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary).font(.caption)
                Text(message.text.highlighted(query: highlight))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

        case .system:
            Text(message.text.highlighted(query: highlight))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var renderedAssistant: some View {
        if message.isStreaming {
            // Plain Text during streaming — fast, no WKWebView overhead.
            // Strip citation markers so they don't appear raw mid-stream.
            Text(message.text.strippingCitationMarkers().highlighted(query: highlight))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // WKWebView renderer: supports drag selection across blocks + KaTeX math.
            MarkdownMessageView(markdown: message.text, highlight: highlight, height: $webHeight)
                .frame(height: webHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

// MARK: - String highlighting helpers

extension String {
    /// Strip `[[cite:N|quote]]` markers and replace each with a small superscript `[N]`.
    /// Used in plain-text rendering (streaming + user/tool messages) so the raw markers
    /// don't appear before the WKWebView renderer takes over.
    func strippingCitationMarkers() -> String {
        let pattern = #"\[\[(?:cite|web):[^|\]]+?\|(?:.+?)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return self
        }
        let ns = self as NSString
        let matches = regex.matches(in: self, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return self }
        var result = ""
        var cursor = 0
        for (i, m) in matches.enumerated() {
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            result += " [\(i+1)]"
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    /// Count case-insensitive occurrences of `query`.
    func occurrences(of query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var count = 0
        var start = startIndex
        while start < endIndex,
              let r = range(of: query, options: .caseInsensitive, range: start..<endIndex) {
            count += 1
            start = r.upperBound
        }
        return count
    }

    /// Returns an AttributedString with `query` matches wrapped in a yellow background.
    func highlighted(query: String) -> AttributedString {
        var attr = AttributedString(self)
        guard !query.isEmpty else { return attr }
        var cursor = attr.startIndex
        while cursor < attr.endIndex,
              let r = attr[cursor..<attr.endIndex].range(of: query, options: .caseInsensitive) {
            attr[r].backgroundColor = Color(red: 1.0, green: 0.88, blue: 0.51)  // #ffe082
            attr[r].foregroundColor = .black
            cursor = r.upperBound
        }
        return attr
    }
}
