import Foundation

enum UsageIdentityStoreError: LocalizedError {
    case readFailed(underlying: Error)
    case invalidFormat(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let underlying):
            return "Failed to read identity cache: \(underlying.localizedDescription)"
        case .invalidFormat:
            return "Identity cache is corrupted (invalid JSON). Delete `~/.claude-island/usage-identities.json` to reset."
        }
    }
}

/// Persists last-known display identities (email/tier/team) keyed by provider accountId.
///
/// This is intentionally separate from the CLI credential snapshot. We only store display data so the UI can
/// keep showing the account email even when usage fetching fails (e.g. auth expired).
actor UsageIdentityStore {
    struct Identity: Codable, Sendable, Equatable {
        var email: String?
        var tier: String?
        var claudeIsTeam: Bool?
    }

    private let rootDir: URL
    private let fileManager: FileManager

    private var loaded = false
    private var identities: [String: Identity] = [:]

    init(
        rootDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-island"),
        fileManager: FileManager = .default
    ) {
        self.rootDir = rootDir
        self.fileManager = fileManager
    }

    private var fileURL: URL {
        rootDir.appendingPathComponent("usage-identities.json")
    }

    func snapshot() throws -> [String: Identity] {
        try loadIfNeeded()
        return identities
    }

    func update(accountId: String, email: String?, tier: String?, claudeIsTeam: Bool?) throws {
        try loadIfNeeded()

        let normalizedEmail: String? = {
            guard let email else { return nil }
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let normalizedTier: String? = {
            guard let tier else { return nil }
            let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        var next = identities[accountId] ?? Identity(email: nil, tier: nil, claudeIsTeam: nil)
        var changed = false

        if let normalizedEmail, normalizedEmail != next.email {
            next.email = normalizedEmail
            changed = true
        }

        if let normalizedTier, normalizedTier != next.tier {
            next.tier = normalizedTier
            changed = true
        }

        if let claudeIsTeam, claudeIsTeam != next.claudeIsTeam {
            next.claudeIsTeam = claudeIsTeam
            changed = true
        }

        guard changed else { return }
        identities[accountId] = next
        try save()
    }

    // MARK: - Internals

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true

        guard fileManager.fileExists(atPath: fileURL.path) else {
            identities = [:]
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw UsageIdentityStoreError.readFailed(underlying: error)
        }

        do {
            identities = try JSONDecoder().decode([String: Identity].self, from: data)
        } catch {
            throw UsageIdentityStoreError.invalidFormat(underlying: error)
        }
    }

    private func save() throws {
        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identities)
        try data.write(to: fileURL, options: [.atomic])
        // Best-effort: keep this file user-readable only.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
