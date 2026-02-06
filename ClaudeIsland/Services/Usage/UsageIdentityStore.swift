import Foundation

enum UsageIdentityStoreError: LocalizedError {
    case readFailed(underlying: Error)
    case invalidFormat(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let underlying):
            return "Failed to read identity cache: \(underlying.localizedDescription)"
        case .invalidFormat:
            return "Identity cache is corrupted (invalid JSON). Delete `~/.agent-island/usage-identities.json` to reset."
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
        /// User-maintained plan override (e.g. pro/max5/max20). If nil, we fall back to inferred tier.
        ///
        /// We intentionally encode this field even when nil so the JSON stays easy to edit by hand.
        var plan: String?
        var claudeIsTeam: Bool?

        enum CodingKeys: String, CodingKey {
            case email
            case tier
            case plan
            case claudeIsTeam
        }

        init(email: String?, tier: String?, plan: String?, claudeIsTeam: Bool?) {
            self.email = email
            self.tier = tier
            self.plan = plan
            self.claudeIsTeam = claudeIsTeam
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            tier = try container.decodeIfPresent(String.self, forKey: .tier)
            plan = try container.decodeIfPresent(String.self, forKey: .plan)
            claudeIsTeam = try container.decodeIfPresent(Bool.self, forKey: .claudeIsTeam)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(email, forKey: .email)
            try container.encodeIfPresent(tier, forKey: .tier)
            try container.encode(plan, forKey: .plan)
            try container.encodeIfPresent(claudeIsTeam, forKey: .claudeIsTeam)
        }
    }

    private let rootDir: URL
    private let fileManager: FileManager

    private var loaded = false
    private var identities: [String: Identity] = [:]

    init(
        rootDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-island"),
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

        var next = identities[accountId] ?? Identity(email: nil, tier: nil, plan: nil, claudeIsTeam: nil)
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

        let hadPlanKey = String(decoding: data, as: UTF8.self).contains("\"plan\"")

        do {
            identities = try JSONDecoder().decode([String: Identity].self, from: data)
        } catch {
            throw UsageIdentityStoreError.invalidFormat(underlying: error)
        }

        // Schema upgrade: older files won't include `plan`. Re-write once so the field is present (as null) for
        // easy manual editing.
        if !hadPlanKey {
            try save()
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
