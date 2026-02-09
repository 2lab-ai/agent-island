import CryptoKit
import Foundation

enum UsageCredentialHasher {
    static func fingerprint(service: UsageService, data: Data) -> (accountId: String, hashPrefix: String) {
        let digestInput: Data
        if let stableKey = stableFingerprintKey(service: service, data: data) {
            digestInput = Data(stableKey.utf8)
        } else {
            digestInput = data
        }

        let digest = SHA256.hash(data: digestInput)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let hashPrefix = String(hex.prefix(16))

        if service == .claude,
           let canonicalClaudeID = claudeCanonicalAccountId(data: data) {
            return (accountId: canonicalClaudeID, hashPrefix: hashPrefix)
        }

        return (accountId: "acct_\(service.rawValue)_\(hashPrefix)", hashPrefix: hashPrefix)
    }

    static func claudeCanonicalAccountId(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let email = extractClaudeEmail(in: root) else { return nil }
        guard let emailSlug = emailSlug(email) else { return nil }
        if extractClaudeIsTeam(in: root) == true {
            return "acct_claude_team_\(emailSlug)"
        }
        return "acct_claude_\(emailSlug)"
    }

    private static func stableFingerprintKey(service: UsageService, data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        switch service {
        case .claude:
            guard let dict = root as? [String: Any] else { return nil }
            let oauth = dict["claudeAiOauth"] as? [String: Any]
            guard let refreshToken = normalizedString(oauth?["refreshToken"]) else { return nil }
            return "claude:refresh:\(refreshToken)"
        case .codex:
            guard let dict = root as? [String: Any] else { return nil }
            let tokens = dict["tokens"] as? [String: Any]
            guard let accountID = normalizedString(tokens?["account_id"]) else { return nil }
            return "codex:account:\(accountID)"
        case .gemini:
            guard let dict = root as? [String: Any] else { return nil }
            let tokenRoot = dict["token"] as? [String: Any]
            if let refreshToken = normalizedString(dict["refresh_token"]) {
                return "gemini:refresh:\(refreshToken)"
            }
            if let refreshToken = normalizedString(tokenRoot?["refreshToken"]) {
                return "gemini:refresh:\(refreshToken)"
            }
            return nil
        }
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractClaudeEmail(in root: [String: Any]) -> String? {
        if let email = normalizedEmail(root["email"] as? String) { return email }
        if let account = root["account"] as? [String: Any],
           let email = normalizedEmail(account["email"] as? String) {
            return email
        }

        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            if let email = normalizedEmail(oauth["email"] as? String) { return email }
            if let account = oauth["account"] as? [String: Any],
               let email = normalizedEmail(account["email"] as? String) {
                return email
            }
            if let accessToken = normalizedString(oauth["accessToken"]),
               let email = decodeJWTEmail(from: accessToken) {
                return email
            }
        }

        return nil
    }

    private static func extractClaudeIsTeam(in root: [String: Any]) -> Bool? {
        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            if let isTeam = parseClaudeIsTeam(from: oauth["isTeam"]) { return isTeam }
            if let type = normalizedString(oauth["subscriptionType"]) {
                return type.lowercased().contains("team")
            }
        }

        if let isTeam = parseClaudeIsTeam(from: root["isTeam"]) { return isTeam }
        if let type = normalizedString(root["subscriptionType"]) {
            return type.lowercased().contains("team")
        }

        return nil
    }

    private static func parseClaudeIsTeam(from value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = normalizedString(value) {
            let lowered = string.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
            if lowered.contains("team") { return true }
        }
        return nil
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func emailSlug(_ email: String) -> String? {
        let lowered = email.lowercased()
        var output: [UInt8] = []
        output.reserveCapacity(lowered.utf8.count)

        var lastWasUnderscore = false
        for byte in lowered.utf8 {
            let isDigit = byte >= 48 && byte <= 57
            let isLower = byte >= 97 && byte <= 122
            if isDigit || isLower {
                output.append(byte)
                lastWasUnderscore = false
            } else {
                guard !lastWasUnderscore else { continue }
                output.append(95) // "_"
                lastWasUnderscore = true
            }
        }

        let raw = String(decoding: output, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeJWTEmail(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let payloadData = decodeBase64URL(String(parts[1])) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }

        if let email = normalizedEmail(root["email"] as? String) { return email }
        if let email = normalizedEmail(root["preferred_username"] as? String) { return email }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

struct ProfileSaveResult {
    let profile: UsageProfile
    let accountsWritten: [UsageAccount]
    let warnings: [String]
}

struct ProfileSwitchResult {
    let profileName: String
    let claudeSwitched: Bool
    let codexSwitched: Bool
    let geminiSwitched: Bool
    let warnings: [String]
}

enum ProfileSwitcherError: LocalizedError {
    case invalidProfileName
    case profileNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            return "Profile name is required."
        case .profileNotFound(let name):
            return "Profile not found: \(name)"
        }
    }
}

final class ProfileSwitcher {
    private let accountStore: AccountStore
    private let exporter: CredentialExporter
    private let fileManager: FileManager
    private let activeHomeDir: URL
    private let rootDir: URL
    private let accountsDir: URL

    init(
        accountStore: AccountStore = AccountStore(),
        exporter: CredentialExporter = CredentialExporter(),
        fileManager: FileManager = .default,
        activeHomeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.accountStore = accountStore
        self.exporter = exporter
        self.fileManager = fileManager
        self.activeHomeDir = activeHomeDir
        self.rootDir = activeHomeDir.appendingPathComponent(".agent-island", isDirectory: true)
        self.accountsDir = rootDir.appendingPathComponent("accounts", isDirectory: true)
    }

    func saveCurrentProfile(named name: String) throws -> ProfileSaveResult {
        let credentials = exporter.loadCurrentCredentials()
        return try saveProfile(named: name, credentials: credentials)
    }

    func saveProfile(named name: String, credentials: ExportCredentials) throws -> ProfileSaveResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileSwitcherError.invalidProfileName
        }

        _ = try migrateStoredClaudeAccountsUsingIdentityCache()
        try fileManager.createDirectory(at: accountsDir, withIntermediateDirectories: true)

        var snapshot = try accountStore.loadSnapshot()
        var warnings: [String] = []
        var accountsWritten: [UsageAccount] = []

        var profile = snapshot.profiles.first(where: { $0.name == trimmed })
            ?? UsageProfile(name: trimmed, claudeAccountId: nil, codexAccountId: nil, geminiAccountId: nil)

        let now = Date()
        if let data = credentials.claude {
            let (account, written) = try writeAccount(
                service: .claude,
                data: data,
                updatedAt: now,
                snapshot: &snapshot
            )
            profile = UsageProfile(
                name: trimmed,
                claudeAccountId: account.id,
                codexAccountId: profile.codexAccountId,
                geminiAccountId: profile.geminiAccountId
            )
            if written { accountsWritten.append(account) }
        } else {
            warnings.append("Claude credentials not found")
        }

        if let data = credentials.codex {
            if hasCodexRequiredTokens(data) {
                let (account, written) = try writeAccount(
                    service: .codex,
                    data: data,
                    updatedAt: now,
                    snapshot: &snapshot
                )
                profile = UsageProfile(
                    name: trimmed,
                    claudeAccountId: profile.claudeAccountId,
                    codexAccountId: account.id,
                    geminiAccountId: profile.geminiAccountId
                )
                if written { accountsWritten.append(account) }
            } else {
                warnings.append("Codex credentials incomplete (missing tokens.access_token/account_id/id_token)")
            }
        } else {
            warnings.append("Codex credentials not found")
        }

        if let data = credentials.gemini {
            let (account, written) = try writeAccount(
                service: .gemini,
                data: data,
                updatedAt: now,
                snapshot: &snapshot
            )
            profile = UsageProfile(
                name: trimmed,
                claudeAccountId: profile.claudeAccountId,
                codexAccountId: profile.codexAccountId,
                geminiAccountId: account.id
            )
            if written { accountsWritten.append(account) }
        } else {
            warnings.append("Gemini credentials not found")
        }

        upsertProfile(profile, snapshot: &snapshot)
        try accountStore.saveSnapshot(snapshot)

        return ProfileSaveResult(profile: profile, accountsWritten: accountsWritten, warnings: warnings)
    }

    func switchToProfile(named name: String) throws -> ProfileSwitchResult {
        let snapshot = try accountStore.loadSnapshot()
        guard let profile = snapshot.profiles.first(where: { $0.name == name }) else {
            throw ProfileSwitcherError.profileNotFound(name: name)
        }
        return try switchToProfile(profile, accounts: snapshot.accounts)
    }

    func switchToProfile(_ profile: UsageProfile) throws -> ProfileSwitchResult {
        let snapshot = try accountStore.loadSnapshot()
        return try switchToProfile(profile, accounts: snapshot.accounts)
    }

    @discardableResult
    func migrateStoredClaudeAccountsUsingIdentityCache() throws -> Bool {
        var snapshot = try accountStore.loadSnapshot()
        let identities = try loadUsageIdentityMap()
        var remap: [String: String] = [:]

        for account in snapshot.accounts where account.service == .claude {
            guard let identity = identities[account.id] else { continue }
            guard let canonicalID = canonicalClaudeAccountId(email: identity.email, isTeam: identity.claudeIsTeam) else { continue }
            guard canonicalID != account.id else { continue }
            remap[account.id] = canonicalID
        }

        guard !remap.isEmpty else { return false }
        try applyClaudeAccountRemap(remap, snapshot: &snapshot)
        try accountStore.saveSnapshot(snapshot)
        return true
    }

    @discardableResult
    func canonicalizeClaudeAccountIfNeeded(accountId: String, email: String?, isTeam: Bool?) throws -> String {
        let normalizedAccountID = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccountID.isEmpty else { return accountId }
        guard let canonicalID = canonicalClaudeAccountId(email: email, isTeam: isTeam) else { return accountId }
        guard canonicalID != normalizedAccountID else { return canonicalID }

        var snapshot = try accountStore.loadSnapshot()
        guard snapshot.accounts.contains(where: { $0.id == normalizedAccountID && $0.service == .claude }) else {
            return accountId
        }

        try applyClaudeAccountRemap([normalizedAccountID: canonicalID], snapshot: &snapshot)
        try accountStore.saveSnapshot(snapshot)
        return canonicalID
    }

    // MARK: - Internals

    private func switchToProfile(_ profile: UsageProfile, accounts: [UsageAccount]) throws -> ProfileSwitchResult {
        var warnings: [String] = []
        var claudeSwitched = false
        var codexSwitched = false
        var geminiSwitched = false

        if let id = profile.claudeAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".claude/.credentials.json")
                let dst = activeHomeDir.appendingPathComponent(".claude/.credentials.json")
                if copyCredentialFileIfPresent(from: src, to: dst) {
                    claudeSwitched = true
                } else {
                    warnings.append("Claude credentials missing for account \(id)")
                }
            } else {
                warnings.append("Claude account not found: \(id)")
            }
        }

        if let id = profile.codexAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".codex/auth.json")
                let dst = activeHomeDir.appendingPathComponent(".codex/auth.json")
                if copyCodexCredentialFileIfPresent(from: src, to: dst) {
                    codexSwitched = true
                } else {
                    warnings.append("Codex credentials missing or invalid for account \(id)")
                }
            } else {
                warnings.append("Codex account not found: \(id)")
            }
        }

        if let id = profile.geminiAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".gemini/oauth_creds.json")
                let dst = activeHomeDir.appendingPathComponent(".gemini/oauth_creds.json")
                if copyCredentialFileIfPresent(from: src, to: dst) {
                    geminiSwitched = true
                } else {
                    warnings.append("Gemini credentials missing for account \(id)")
                }
            } else {
                warnings.append("Gemini account not found: \(id)")
            }
        }

        return ProfileSwitchResult(
            profileName: profile.name,
            claudeSwitched: claudeSwitched,
            codexSwitched: codexSwitched,
            geminiSwitched: geminiSwitched,
            warnings: warnings
        )
    }

    private struct UsageIdentityEntry: Codable {
        var email: String?
        var tier: String?
        var plan: String?
        var claudeIsTeam: Bool?
    }

    private struct ClaudeCodeTokenEntry: Codable {
        var token: String
        var enabled: Bool
    }

    private var usageIdentitiesURL: URL {
        rootDir.appendingPathComponent("usage-identities.json")
    }

    private var claudeCodeTokensURL: URL {
        rootDir.appendingPathComponent("claude-code-tokens.json")
    }

    private func resolveCanonicalClaudeAccountId(data: Data, fallbackAccountId: String) -> String? {
        if let canonicalID = UsageCredentialHasher.claudeCanonicalAccountId(data: data) {
            return canonicalID
        }

        guard let identities = try? loadUsageIdentityMap(),
              let identity = identities[fallbackAccountId]
        else {
            return nil
        }

        return canonicalClaudeAccountId(email: identity.email, isTeam: identity.claudeIsTeam)
    }

    private func canonicalClaudeAccountId(email: String?, isTeam: Bool?) -> String? {
        guard let normalized = normalizedEmail(email) else { return nil }
        guard let slug = emailSlug(normalized) else { return nil }
        if isTeam == true {
            return "acct_claude_team_\(slug)"
        }
        return "acct_claude_\(slug)"
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.contains("@") else { return nil }
        return trimmed
    }

    private func emailSlug(_ email: String) -> String? {
        let lowered = email.lowercased()
        var output: [UInt8] = []
        output.reserveCapacity(lowered.utf8.count)

        var lastWasUnderscore = false
        for byte in lowered.utf8 {
            let isDigit = byte >= 48 && byte <= 57
            let isLower = byte >= 97 && byte <= 122
            if isDigit || isLower {
                output.append(byte)
                lastWasUnderscore = false
            } else {
                guard !lastWasUnderscore else { continue }
                output.append(95) // "_"
                lastWasUnderscore = true
            }
        }

        let raw = String(decoding: output, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyClaudeAccountRemap(_ remap: [String: String], snapshot: inout AccountsSnapshot) throws {
        let normalizedRemap = normalizeRemap(remap)
        guard !normalizedRemap.isEmpty else { return }

        let claudeAccounts = snapshot.accounts
            .filter { $0.service == .claude }
            .sorted { $0.updatedAt < $1.updatedAt }

        var latestUpdatedAtByTargetID: [String: Date] = [:]
        for account in claudeAccounts {
            let targetID = resolveRemappedID(account.id, remap: normalizedRemap)
            if let existing = latestUpdatedAtByTargetID[targetID] {
                if account.updatedAt > existing {
                    latestUpdatedAtByTargetID[targetID] = account.updatedAt
                }
            } else {
                latestUpdatedAtByTargetID[targetID] = account.updatedAt
            }
        }

        var mergedClaudeByID: [String: UsageAccount] = [:]
        for account in claudeAccounts {
            let targetID = resolveRemappedID(account.id, remap: normalizedRemap)
            let targetRoot = accountsDir.appendingPathComponent(targetID, isDirectory: true)
            let sourceRoot = URL(fileURLWithPath: account.rootPath, isDirectory: true)
            let shouldPromoteCredentials = account.updatedAt >= (latestUpdatedAtByTargetID[targetID] ?? account.updatedAt)

            if sourceRoot.standardizedFileURL.path != targetRoot.standardizedFileURL.path {
                try migrateClaudeAccountDirectory(
                    from: sourceRoot,
                    to: targetRoot,
                    overwriteDestinationCredentials: shouldPromoteCredentials
                )
            }

            let targetLabel: String
            if targetID.hasPrefix("acct_claude_") {
                let suffix = String(targetID.dropFirst("acct_claude_".count))
                targetLabel = "claude:\(suffix)"
            } else {
                targetLabel = account.label
            }

            let remapped = UsageAccount(
                id: targetID,
                service: .claude,
                label: targetLabel,
                rootPath: targetRoot.path,
                updatedAt: account.updatedAt
            )

            if let existing = mergedClaudeByID[targetID] {
                if remapped.updatedAt >= existing.updatedAt {
                    mergedClaudeByID[targetID] = remapped
                }
            } else {
                mergedClaudeByID[targetID] = remapped
            }
        }

        let nonClaudeAccounts = snapshot.accounts.filter { $0.service != .claude }
        let mergedClaudeAccounts = mergedClaudeByID.values.sorted { $0.updatedAt > $1.updatedAt }
        snapshot.accounts = nonClaudeAccounts + mergedClaudeAccounts

        snapshot.profiles = snapshot.profiles.map { profile in
            guard let claudeID = profile.claudeAccountId else { return profile }
            let remappedID = resolveRemappedID(claudeID, remap: normalizedRemap)
            guard remappedID != claudeID else { return profile }
            return UsageProfile(
                name: profile.name,
                claudeAccountId: remappedID,
                codexAccountId: profile.codexAccountId,
                geminiAccountId: profile.geminiAccountId
            )
        }

        try remapUsageIdentities(normalizedRemap)
        try remapClaudeCodeTokens(normalizedRemap)
    }

    private func normalizeRemap(_ remap: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (source, _) in remap {
            let resolved = resolveRemappedID(source, remap: remap)
            if source != resolved {
                normalized[source] = resolved
            }
        }
        return normalized
    }

    private func resolveRemappedID(_ accountId: String, remap: [String: String]) -> String {
        var current = accountId
        var visited: Set<String> = []
        while let next = remap[current], next != current, !visited.contains(next) {
            visited.insert(current)
            current = next
        }
        return current
    }

    private func migrateClaudeAccountDirectory(
        from sourceRoot: URL,
        to destinationRoot: URL,
        overwriteDestinationCredentials: Bool
    ) throws {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let destinationPath = destinationRoot.standardizedFileURL.path
        guard sourcePath != destinationPath else { return }

        let sourceExists = fileManager.fileExists(atPath: sourcePath)
        guard sourceExists else { return }

        if !fileManager.fileExists(atPath: destinationPath) {
            try fileManager.createDirectory(at: destinationRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: sourceRoot, to: destinationRoot)
            return
        }

        let sourceClaudeCred = sourceRoot.appendingPathComponent(".claude/.credentials.json")
        let destinationClaudeCred = destinationRoot.appendingPathComponent(".claude/.credentials.json")
        if overwriteDestinationCredentials,
           fileManager.fileExists(atPath: sourceClaudeCred.path) {
            try fileManager.createDirectory(at: destinationClaudeCred.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationClaudeCred.path) {
                try fileManager.removeItem(at: destinationClaudeCred)
            }
            try fileManager.copyItem(at: sourceClaudeCred, to: destinationClaudeCred)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationClaudeCred.path)
        }

        try? fileManager.removeItem(at: sourceRoot)
    }

    private func remapUsageIdentities(_ remap: [String: String]) throws {
        guard !remap.isEmpty else { return }
        var identities = try loadUsageIdentityMap()
        guard !identities.isEmpty else { return }

        var changed = false
        for (source, target) in remap where source != target {
            guard let sourceEntry = identities.removeValue(forKey: source) else { continue }
            changed = true
            if let existing = identities[target] {
                identities[target] = mergeUsageIdentity(existing: existing, incoming: sourceEntry)
            } else {
                identities[target] = sourceEntry
            }
        }

        if changed {
            try saveUsageIdentityMap(identities)
        }
    }

    private func mergeUsageIdentity(existing: UsageIdentityEntry, incoming: UsageIdentityEntry) -> UsageIdentityEntry {
        UsageIdentityEntry(
            email: normalizedEmail(existing.email) ?? normalizedEmail(incoming.email),
            tier: trimmedNonEmpty(existing.tier) ?? trimmedNonEmpty(incoming.tier),
            plan: trimmedNonEmpty(existing.plan) ?? trimmedNonEmpty(incoming.plan),
            claudeIsTeam: existing.claudeIsTeam ?? incoming.claudeIsTeam
        )
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadUsageIdentityMap() throws -> [String: UsageIdentityEntry] {
        guard fileManager.fileExists(atPath: usageIdentitiesURL.path) else { return [:] }
        let data = try Data(contentsOf: usageIdentitiesURL)
        return try JSONDecoder().decode([String: UsageIdentityEntry].self, from: data)
    }

    private func saveUsageIdentityMap(_ identities: [String: UsageIdentityEntry]) throws {
        try fileManager.createDirectory(at: usageIdentitiesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identities)
        try data.write(to: usageIdentitiesURL, options: [.atomic])
    }

    private func remapClaudeCodeTokens(_ remap: [String: String]) throws {
        guard !remap.isEmpty else { return }
        var entries = try loadClaudeCodeTokenMap()
        guard !entries.isEmpty else { return }

        var changed = false
        for (source, target) in remap where source != target {
            guard let sourceEntry = entries.removeValue(forKey: source) else { continue }
            changed = true
            if let existing = entries[target] {
                entries[target] = mergeClaudeCodeToken(existing: existing, incoming: sourceEntry)
            } else {
                entries[target] = sourceEntry
            }
        }

        if changed {
            try saveClaudeCodeTokenMap(entries)
        }
    }

    private func mergeClaudeCodeToken(existing: ClaudeCodeTokenEntry, incoming: ClaudeCodeTokenEntry) -> ClaudeCodeTokenEntry {
        let existingToken = existing.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingToken.isEmpty {
            return ClaudeCodeTokenEntry(token: existingToken, enabled: existing.enabled)
        }
        let incomingToken = incoming.token.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCodeTokenEntry(token: incomingToken, enabled: incoming.enabled)
    }

    private func loadClaudeCodeTokenMap() throws -> [String: ClaudeCodeTokenEntry] {
        guard fileManager.fileExists(atPath: claudeCodeTokensURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeCodeTokensURL)

        if let decoded = try? JSONDecoder().decode([String: ClaudeCodeTokenEntry].self, from: data) {
            return decoded
        }

        let legacy = try JSONDecoder().decode([String: String].self, from: data)
        return legacy.reduce(into: [String: ClaudeCodeTokenEntry]()) { partial, pair in
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            partial[pair.key] = ClaudeCodeTokenEntry(token: token, enabled: true)
        }
    }

    private func saveClaudeCodeTokenMap(_ entries: [String: ClaudeCodeTokenEntry]) throws {
        try fileManager.createDirectory(at: claudeCodeTokensURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: claudeCodeTokensURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeCodeTokensURL.path)
    }

    private func upsertProfile(_ profile: UsageProfile, snapshot: inout AccountsSnapshot) {
        if let idx = snapshot.profiles.firstIndex(where: { $0.name == profile.name }) {
            snapshot.profiles[idx] = profile
        } else {
            snapshot.profiles.append(profile)
        }
    }

    private func writeAccount(
        service: UsageService,
        data: Data,
        updatedAt: Date,
        snapshot: inout AccountsSnapshot
    ) throws -> (account: UsageAccount, written: Bool) {
        let fingerprint = UsageCredentialHasher.fingerprint(service: service, data: data)
        var accountId = fingerprint.accountId
        let hashPrefix = fingerprint.hashPrefix

        let exportCredentials: ExportCredentials
        switch service {
        case .claude:
            if let canonicalClaudeID = resolveCanonicalClaudeAccountId(data: data, fallbackAccountId: fingerprint.accountId) {
                accountId = canonicalClaudeID
            }
            exportCredentials = ExportCredentials(claude: data, codex: nil, gemini: nil)
        case .codex:
            exportCredentials = ExportCredentials(claude: nil, codex: data, gemini: nil)
        case .gemini:
            exportCredentials = ExportCredentials(claude: nil, codex: nil, gemini: data)
        }

        let root = accountsDir.appendingPathComponent(accountId, isDirectory: true)
        _ = try exporter.export(exportCredentials, to: root)

        let account = UsageAccount(
            id: accountId,
            service: service,
            label: "\(service.rawValue):\(hashPrefix)",
            rootPath: root.path,
            updatedAt: updatedAt
        )
        upsertAccount(account, snapshot: &snapshot)

        return (account, true)
    }

    private func upsertAccount(_ account: UsageAccount, snapshot: inout AccountsSnapshot) {
        if let idx = snapshot.accounts.firstIndex(where: { $0.id == account.id }) {
            snapshot.accounts[idx] = account
        } else {
            snapshot.accounts.append(account)
        }
    }

    private func copyCredentialFileIfPresent(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }

        do {
            let data = try Data(contentsOf: sourceURL)
            try writeCredentialData(data, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private func copyCodexCredentialFileIfPresent(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }

        do {
            let sourceData = try Data(contentsOf: sourceURL)
            guard var root = parseJSONObject(sourceData),
                  var sourceTokens = root["tokens"] as? [String: Any]
            else {
                return false
            }

            if normalizedCodexToken(sourceTokens["id_token"]) == nil {
                guard
                    let sourceAccountId = normalizedCodexToken(sourceTokens["account_id"]),
                    let destinationData = try? Data(contentsOf: destinationURL),
                    let destinationRoot = parseJSONObject(destinationData),
                    let destinationTokens = destinationRoot["tokens"] as? [String: Any],
                    let destinationAccountId = normalizedCodexToken(destinationTokens["account_id"]),
                    let destinationIDToken = normalizedCodexToken(destinationTokens["id_token"]),
                    sourceAccountId == destinationAccountId
                else {
                    return false
                }

                sourceTokens["id_token"] = destinationIDToken
                if sourceTokens["refresh_token"] == nil,
                   let destinationRefreshToken = normalizedCodexToken(destinationTokens["refresh_token"]) {
                    sourceTokens["refresh_token"] = destinationRefreshToken
                }
                root["tokens"] = sourceTokens
            }

            guard hasCodexRequiredTokens(root) else { return false }

            let mergedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try writeCredentialData(mergedData, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private func writeCredentialData(_ data: Data, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    private func hasCodexRequiredTokens(_ data: Data) -> Bool {
        guard let root = parseJSONObject(data) else { return false }
        return hasCodexRequiredTokens(root)
    }

    private func hasCodexRequiredTokens(_ root: [String: Any]) -> Bool {
        guard let tokens = root["tokens"] as? [String: Any] else { return false }
        return normalizedCodexToken(tokens["access_token"]) != nil &&
            normalizedCodexToken(tokens["account_id"]) != nil &&
            normalizedCodexToken(tokens["id_token"]) != nil
    }

    private func parseJSONObject(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return json as? [String: Any]
    }

    private func normalizedCodexToken(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
