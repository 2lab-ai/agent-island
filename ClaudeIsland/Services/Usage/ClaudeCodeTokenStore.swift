import Foundation

enum ClaudeCodeTokenStoreError: LocalizedError {
    case readFailed(underlying: Error)
    case invalidFormat(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let underlying):
            return "Failed to read Claude Code token store: \(underlying.localizedDescription)"
        case .invalidFormat:
            return "Claude Code token store is corrupted (invalid JSON). Delete `~/.claude-island/claude-code-tokens.json` to reset."
        }
    }
}

/// Stores long-lived Claude Code OAuth tokens (from `claude setup-token`) keyed by provider accountId.
///
/// - Note: This token is **not** used for usage fetching. It's only used to set `CLAUDE_CODE_OAUTH_TOKEN`
///   when switching profiles so Claude Code can keep working even if the regular CLI OAuth expires.
actor ClaudeCodeTokenStore {
    private let rootDir: URL

    init(rootDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-island")) {
        self.rootDir = rootDir
    }

    private var fileURL: URL {
        rootDir.appendingPathComponent("claude-code-tokens.json")
    }

    func loadToken(accountId: String) throws -> String? {
        let map = try loadAll()
        let trimmed = map[accountId]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func saveToken(accountId: String, token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteToken(accountId: accountId)
            return
        }

        var map = try loadAll()
        map[accountId] = trimmed
        try saveAll(map)
    }

    func deleteToken(accountId: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var map = try loadAll()
        map.removeValue(forKey: accountId)
        try saveAll(map)
    }

    private func loadAll() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ClaudeCodeTokenStoreError.readFailed(underlying: error)
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw ClaudeCodeTokenStoreError.invalidFormat(underlying: error)
        }
    }

    private func saveAll(_ map: [String: String]) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: fileURL, options: [.atomic])
        // Best-effort: keep this file user-readable only since it contains long-lived tokens.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
