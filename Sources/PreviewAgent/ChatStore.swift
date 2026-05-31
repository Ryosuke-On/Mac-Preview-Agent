import Foundation
import CryptoKit

/// Persists chat history and agent session id per file.
struct ChatStore {
    struct Saved: Codable {
        var messages: [Persisted]
        var sessionId: String?
        var agentKind: String?
    }
    struct Persisted: Codable {
        var role: String        // "user" | "assistant" | "tool" | "system"
        var text: String
        var toolName: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    static var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PreviewAgent/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func storeURL(for fileURL: URL) -> URL {
        // Hash the absolute path for a stable key; keep a readable suffix for debugging.
        let path = fileURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let safeName = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(40)
        return rootDir.appendingPathComponent("\(safeName)-\(hex).json")
    }

    static func load(for fileURL: URL) -> Saved? {
        let url = storeURL(for: fileURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, for fileURL: URL) {
        let url = storeURL(for: fileURL)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(for fileURL: URL) {
        try? FileManager.default.removeItem(at: storeURL(for: fileURL))
    }
}
