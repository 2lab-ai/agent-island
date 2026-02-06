import Foundation

enum ClaudeCodeTokenStoreError: LocalizedError {
    case readFailed(underlying: Error)
    case invalidFormat(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let underlying):
            return "Failed to read Claude Code token store: \(underlying.localizedDescription)"
        case .invalidFormat:
            return "Claude Code token store is corrupted (invalid JSON). Delete `~/.agent-island/claude-code-tokens.json` to reset."
        }
    }
}

/// Stores long-lived Claude Code OAuth tokens (from `claude setup-token`) keyed by provider accountId.
///
/// - Note: This token is **not** used for usage fetching. It's only used to set `CLAUDE_CODE_OAUTH_TOKEN`
///   when switching profiles so Claude Code can keep working even if the regular CLI OAuth expires.
struct ClaudeCodeTokenStatus: Sendable, Equatable {
    let isSet: Bool
    let isEnabled: Bool
}

actor ClaudeCodeTokenStore {
    struct Entry: Codable, Sendable, Equatable {
        var token: String
        var enabled: Bool
    }

    private let rootDir: URL

    init(rootDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-island")) {
        self.rootDir = rootDir
    }

    private var fileURL: URL {
        rootDir.appendingPathComponent("claude-code-tokens.json")
    }

    func statusSnapshot() throws -> [String: ClaudeCodeTokenStatus] {
        let entries = try loadAllEntries()
        return entries.mapValues { entry in
            let trimmed = entry.token.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSet = !trimmed.isEmpty
            return ClaudeCodeTokenStatus(isSet: isSet, isEnabled: isSet && entry.enabled)
        }
    }

    func loadTokenIfEnabled(accountId: String) throws -> String? {
        guard let entry = try loadAllEntries()[accountId] else { return nil }
        guard entry.enabled else { return nil }
        let trimmed = entry.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func loadToken(accountId: String) throws -> String? {
        guard let entry = try loadAllEntries()[accountId] else { return nil }
        let trimmed = entry.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func setEnabled(accountId: String, enabled: Bool) throws {
        var entries = try loadAllEntries()
        guard var entry = entries[accountId] else { return }
        entry.enabled = enabled
        entries[accountId] = entry
        try saveAllEntries(entries)
    }

    func saveToken(accountId: String, token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteToken(accountId: accountId)
            return
        }

        var entries = try loadAllEntries()
        let enabled = entries[accountId]?.enabled ?? true
        entries[accountId] = Entry(token: trimmed, enabled: enabled)
        try saveAllEntries(entries)
    }

    func deleteToken(accountId: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var entries = try loadAllEntries()
        entries.removeValue(forKey: accountId)
        try saveAllEntries(entries)
    }

    private func loadAllEntries() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ClaudeCodeTokenStoreError.readFailed(underlying: error)
        }

        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch let primaryError {
            do {
                let legacy = try JSONDecoder().decode([String: String].self, from: data)
                let upgraded = legacy.reduce(into: [String: Entry]()) { partial, pair in
                    let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    partial[pair.key] = Entry(token: token, enabled: true)
                }
                // Best-effort: rewrite in the new format for future edits.
                try saveAllEntries(upgraded)
                return upgraded
            } catch {
                throw ClaudeCodeTokenStoreError.invalidFormat(underlying: primaryError)
            }
        }
    }

    private func saveAllEntries(_ map: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: fileURL, options: [.atomic])
        // Best-effort: keep this file user-readable only since it contains long-lived tokens.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
