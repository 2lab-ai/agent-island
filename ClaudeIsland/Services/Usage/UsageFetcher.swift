import CryptoKit
import Darwin
import Foundation

struct UsageIdentities: Sendable {
    let claudeEmail: String?
    let claudeTier: String?
    let claudeIsTeam: Bool?
    let codexEmail: String?
    let geminiEmail: String?

    static let empty = UsageIdentities(
        claudeEmail: nil,
        claudeTier: nil,
        claudeIsTeam: nil,
        codexEmail: nil,
        geminiEmail: nil
    )
}

struct TokenRefreshInfo: Sendable {
    let expiresAt: Date
    let lifetimeSeconds: TimeInterval
}

struct UsageTokenRefresh: Sendable {
    let claude: TokenRefreshInfo?
    let codex: TokenRefreshInfo?
    let gemini: TokenRefreshInfo?

    static let empty = UsageTokenRefresh(claude: nil, codex: nil, gemini: nil)
}

enum UsageIssueKind: Sendable, Equatable {
    case cauthUnavailable
}

struct UsageIssue: Sendable, Equatable {
    let kind: UsageIssueKind
    let message: String
    let technicalDetails: String?
}

struct UsageSnapshot: Sendable, Identifiable {
    let profileName: String
    let output: CheckUsageOutput?
    let identities: UsageIdentities
    let tokenRefresh: UsageTokenRefresh
    let fetchedAt: Date?
    let isStale: Bool
    let errorMessage: String?
    let issue: UsageIssue?

    var id: String { profileName }
}

enum UsageFetcherError: LocalizedError {
    case invalidJSON(underlying: Error)
    case noCredentialsFound
    case cauthNotImplemented

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Failed to parse check-usage JSON output."
        case .noCredentialsFound:
            return "No CLI credentials found for Claude/Codex/Gemini. Log in and try again."
        case .cauthNotImplemented:
            return "cauth CLI integration is not yet implemented."
        }
    }
}

final class UsageFetcher {
    private static let claudeRefreshLockRegistry = ClaudeRefreshLockRegistry()

    private let accountStore: AccountStore
    private let cache: UsageCache
    private let homeDirectory: URL
    private let refreshLogWriter: UsageRefreshLogWriter
    private let identityCache = IdentityCache()

    init(
        accountStore: AccountStore = AccountStore(),
        cache: UsageCache = UsageCache(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.accountStore = accountStore
        self.cache = cache
        self.homeDirectory = homeDirectory
        self.refreshLogWriter = UsageRefreshLogWriter(homeDirectory: homeDirectory)
    }

    func fetchSnapshot(for profile: UsageProfile, forceRefresh: Bool = false) async -> UsageSnapshot {
        var tokenRefresh = UsageTokenRefresh.empty
        var cachedIdentities = UsageIdentities.empty
        var identityKey = "profile:\(profile.name)"
        var accounts: [UsageAccount] = []

        do {
            let snapshot = try accountStore.loadSnapshot()
            accounts = snapshot.accounts
            let credentials = loadCredentials(profile: profile, accounts: snapshot.accounts)
            identityKey = identityCacheKey(namespace: "profile:\(profile.name)", credentials: credentials)

            tokenRefresh = resolveTokenRefresh(credentials: credentials)
            cachedIdentities = await resolveIdentitiesCached(key: identityKey, credentials: credentials)

            if !forceRefresh, let entry = await cache.getFresh(profileName: profile.name) {
                return UsageSnapshot(
                    profileName: profile.name,
                    output: entry.output,
                    identities: cachedIdentities,
                    tokenRefresh: tokenRefresh,
                    fetchedAt: entry.fetchedAt,
                    isStale: false,
                    errorMessage: nil,
                    issue: nil
                )
            }

            // TODO: Replace with cauth CLI call
            let output = try await fetchUsageFromCauth(accountId: profile.claudeAccountId)
            let refreshedCredentials = loadCredentials(profile: profile, accounts: snapshot.accounts)
            tokenRefresh = resolveTokenRefresh(credentials: refreshedCredentials)

            await cache.set(profileName: profile.name, output: output)
            let entry = await cache.getAny(profileName: profile.name)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output ?? output,
                identities: cachedIdentities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil,
                issue: nil
            )
        } catch {
            if !accounts.isEmpty {
                let latestCredentials = loadCredentials(profile: profile, accounts: accounts)
                tokenRefresh = resolveTokenRefresh(credentials: latestCredentials)
            }

            let entry = await cache.getAny(profileName: profile.name)
            let identities = await identityCache.getFresh(key: identityKey) ?? cachedIdentities
            let issue = Self.classifyIssue(from: error)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: issue?.message ?? error.localizedDescription,
                issue: issue
            )
        }
    }

    func fetchCurrentSnapshot(credentials: ExportCredentials, forceRefresh: Bool = false) async -> UsageSnapshot {
        let cacheKey = "__current__"
        let profileName = "Current"
        let identityKey = identityCacheKey(namespace: cacheKey, credentials: credentials)

        var tokenRefresh = resolveTokenRefresh(credentials: credentials)
        let identities = await resolveIdentitiesCached(key: identityKey, credentials: credentials)

        if !forceRefresh, let entry = await cache.getFresh(profileName: cacheKey) {
            return UsageSnapshot(
                profileName: profileName,
                output: entry.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry.fetchedAt,
                isStale: false,
                errorMessage: nil,
                issue: nil
            )
        }

        do {
            // TODO: Replace with cauth CLI call
            let output = try await fetchUsageFromCauth(accountId: nil)
            tokenRefresh = resolveTokenRefresh(credentials: loadCurrentCredentialsFromHome())

            await cache.set(profileName: cacheKey, output: output)
            let entry = await cache.getAny(profileName: cacheKey)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output ?? output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil,
                issue: nil
            )
        } catch {
            tokenRefresh = resolveTokenRefresh(credentials: loadCurrentCredentialsFromHome())

            let entry = await cache.getAny(profileName: cacheKey)
            let issue = Self.classifyIssue(from: error)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: issue?.message ?? error.localizedDescription,
                issue: issue
            )
        }
    }

    // MARK: - Internals

    private func fetchUsageFromCauth(accountId: String?) async throws -> CheckUsageOutput {
        // TODO: Replace with cauth CLI call
        throw UsageFetcherError.cauthNotImplemented
    }

    private func credentialRelativePath(for service: UsageService) -> String {
        switch service {
        case .claude:
            return ".claude/.credentials.json"
        case .codex:
            return ".codex/auth.json"
        case .gemini:
            return ".gemini/oauth_creds.json"
        }
    }

    private var sharedClaudeRefreshLockPath: String {
        homeDirectory.appendingPathComponent(".claude/.refresh.lock").path
    }

    private func claudeRefreshLockKeys(profile: UsageProfile, accounts: [UsageAccount]) -> [String] {
        guard let accountId = profile.claudeAccountId,
              let account = accounts.first(where: { $0.id == accountId }) else {
            return []
        }

        let root = URL(fileURLWithPath: account.rootPath, isDirectory: true)
        var keys = [sharedClaudeRefreshLockPath,
                    root.appendingPathComponent(credentialRelativePath(for: .claude)).path]
        let credentialData = loadCredentialFile(
            accounts: accounts,
            accountId: accountId,
            relativePath: credentialRelativePath(for: .claude)
        )
        if let tokenKey = claudeRefreshTokenLockKey(from: credentialData) {
            keys.append(tokenKey)
        }
        return keys
    }

    private func claudeRefreshLockKeys(credentials: ExportCredentials) -> [String] {
        guard credentials.claude != nil else { return [] }
        var keys = [sharedClaudeRefreshLockPath,
                    homeDirectory.appendingPathComponent(credentialRelativePath(for: .claude)).path]
        if let tokenKey = claudeRefreshTokenLockKey(from: credentials.claude) {
            keys.append(tokenKey)
        }
        return keys
    }

    private func claudeRefreshTokenLockKey(from data: Data?) -> String? {
        let fingerprint = claudeTokenFingerprint(from: data)
        guard let refreshFingerprint = fingerprint.refreshFingerprint else { return nil }
        return "claude-refresh-token:\(refreshFingerprint)"
    }

    private func withClaudeRefreshLocks<T>(
        keys: [String],
        traceID: String,
        scope: String,
        operation: () async throws -> T
    ) async throws -> T {
        let normalized = Array(Set(keys.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty else {
            return try await operation()
        }

        return try await withProcessRefreshLocks(keys: normalized, traceID: traceID, scope: scope) {
            logRefresh(event: "refresh_lock_wait", fields: [
                "trace_id": traceID,
                "scope": scope,
                "lock_keys": normalized.joined(separator: ","),
            ])
            await Self.claudeRefreshLockRegistry.acquire(normalized)
            logRefresh(event: "refresh_lock_acquired", fields: [
                "trace_id": traceID,
                "scope": scope,
                "lock_keys": normalized.joined(separator: ","),
            ])

            do {
                let result = try await operation()
                await Self.claudeRefreshLockRegistry.release(normalized)
                logRefresh(event: "refresh_lock_released", fields: [
                    "trace_id": traceID,
                    "scope": scope,
                    "result": "success",
                ])
                return result
            } catch {
                await Self.claudeRefreshLockRegistry.release(normalized)
                logRefresh(event: "refresh_lock_released", fields: [
                    "trace_id": traceID,
                    "scope": scope,
                    "result": "error",
                    "error": String(describing: error),
                ])
                throw error
            }
        }
    }

    private func withProcessRefreshLocks<T>(
        keys: [String],
        traceID: String,
        scope: String,
        operation: () async throws -> T
    ) async throws -> T {
        let lockDir = homeDirectory
            .appendingPathComponent(".agent-island", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)

        logRefresh(event: "refresh_process_lock_wait", fields: [
            "trace_id": traceID,
            "scope": scope,
            "lock_keys": keys.joined(separator: ","),
        ])

        var handles: [ProcessFileLock] = []
        do {
            for key in keys {
                let lockName = processRefreshLockFileName(for: key)
                let lockURL = lockDir.appendingPathComponent(lockName)
                let handle = try ProcessFileLock(path: lockURL.path)
                handles.append(handle)
            }
        } catch {
            handles.reversed().forEach { $0.unlock() }
            logRefresh(event: "refresh_process_lock_failed", fields: [
                "trace_id": traceID,
                "scope": scope,
                "error": String(describing: error),
                "lock_keys": keys.joined(separator: ","),
            ])
            throw error
        }

        logRefresh(event: "refresh_process_lock_acquired", fields: [
            "trace_id": traceID,
            "scope": scope,
            "lock_keys": keys.joined(separator: ","),
        ])

        do {
            let result = try await operation()
            handles.reversed().forEach { $0.unlock() }
            logRefresh(event: "refresh_process_lock_released", fields: [
                "trace_id": traceID,
                "scope": scope,
                "result": "success",
            ])
            return result
        } catch {
            handles.reversed().forEach { $0.unlock() }
            logRefresh(event: "refresh_process_lock_released", fields: [
                "trace_id": traceID,
                "scope": scope,
                "result": "error",
                "error": String(describing: error),
            ])
            throw error
        }
    }

    private func processRefreshLockFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "usage-refresh-\(String(hex.prefix(24))).lock"
    }

    private final class ProcessFileLock {
        private let fd: Int32
        private var isLocked = true

        init(path: String, timeoutSeconds: TimeInterval = 60) throws {
            let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw NSError(
                    domain: "UsageFetcher.ProcessFileLock",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "open(\(path)) failed with errno \(errno)"]
                )
            }

            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
                fd = descriptor
                return
            }

            let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
            let pollInterval: useconds_t = 200_000 // 200ms
            var acquired = false
            while CFAbsoluteTimeGetCurrent() < deadline {
                usleep(pollInterval)
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    acquired = true
                    break
                }
            }

            guard acquired else {
                close(descriptor)
                throw NSError(
                    domain: "UsageFetcher.ProcessFileLock",
                    code: 110, // ETIMEDOUT
                    userInfo: [NSLocalizedDescriptionKey: "flock(\(path)) timed out after \(Int(timeoutSeconds))s"]
                )
            }

            _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
            fd = descriptor
        }

        func unlock() {
            guard isLocked else { return }
            isLocked = false
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        deinit {
            unlock()
        }
    }

    private struct ClaudeTokenFingerprint {
        let refreshFingerprint: String?
        let accessFingerprint: String?
        let expiresAtISO8601: String?
        let expiresAt: Date?
    }

    private func logRefresh(event: String, fields: [String: String?]) {
        refreshLogWriter.write(event: event, fields: fields)
    }

    private func claudeTokenFingerprint(from data: Data?) -> ClaudeTokenFingerprint {
        guard let data else {
            return ClaudeTokenFingerprint(
                refreshFingerprint: nil,
                accessFingerprint: nil,
                expiresAtISO8601: nil,
                expiresAt: nil
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeTokenFingerprint(
                refreshFingerprint: nil,
                accessFingerprint: nil,
                expiresAtISO8601: nil,
                expiresAt: nil
            )
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let refreshToken = oauth["refreshToken"] as? String
        let accessToken = oauth["accessToken"] as? String
        let expiresAt = parseDateFromAny(oauth["expiresAt"])
            ?? parseDateFromAny(oauth["expires_at"])
            ?? parseDateFromAny(root["expiresAt"])
            ?? parseDateFromAny(root["expires_at"])

        return ClaudeTokenFingerprint(
            refreshFingerprint: tokenFingerprint(refreshToken),
            accessFingerprint: tokenFingerprint(accessToken),
            expiresAtISO8601: iso8601String(expiresAt),
            expiresAt: expiresAt
        )
    }

    private func tokenFingerprint(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func iso8601String(_ date: Date?) -> String? {
        guard let date else { return nil }
        return UsageRefreshLogWriter.iso8601Formatter.string(from: date)
    }

    func shouldReuseCachedIdentities(_ identities: UsageIdentities, credentials: ExportCredentials) -> Bool {
        if credentials.claude != nil, identities.claudeEmail == nil {
            return false
        }

        if credentials.codex != nil, identities.codexEmail == nil {
            return false
        }

        if credentials.gemini != nil, identities.geminiEmail == nil {
            return false
        }

        return true
    }

    static func decodeUsageOutput(_ data: Data) throws -> CheckUsageOutput {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CheckUsageOutput.self, from: data)
    }

    static func classifyIssue(from error: Error) -> UsageIssue? {
        if error is UsageFetcherError {
            return UsageIssue(
                kind: .cauthUnavailable,
                message: "cauth CLI integration is not yet available. Usage data will be shown when cauth is connected.",
                technicalDetails: error.localizedDescription
            )
        }

        return nil
    }
}

// MARK: - Identities

private actor IdentityCache {
    struct Entry: Sendable {
        let identities: UsageIdentities
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 3600) {
        self.ttl = ttl
    }

    func getFresh(key: String, now: Date = Date()) -> UsageIdentities? {
        guard let entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.fetchedAt) > ttl { return nil }
        return entry.identities
    }

    func set(key: String, identities: UsageIdentities, fetchedAt: Date = Date()) {
        entries[key] = Entry(identities: identities, fetchedAt: fetchedAt)
    }
}

private extension UsageFetcher {
    func identityCacheKey(namespace: String, credentials: ExportCredentials) -> String {
        "\(namespace)|claude:\(stableDataHash(credentials.claude))|codex:\(stableDataHash(credentials.codex))|gemini:\(stableDataHash(credentials.gemini))"
    }

    // Lightweight in-memory hash for cache keying; avoids reusing identities across credential changes.
    func stableDataHash(_ data: Data?) -> String {
        guard let data else { return "-" }
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    func resolveIdentitiesCached(key: String, credentials: ExportCredentials) async -> UsageIdentities {
        if let cached = await identityCache.getFresh(key: key),
           shouldReuseCachedIdentities(cached, credentials: credentials) {
            return cached
        }
        let identities = await resolveIdentities(credentials: credentials)
        await identityCache.set(key: key, identities: identities)
        return identities
    }

    func loadCredentials(profile: UsageProfile, accounts: [UsageAccount]) -> ExportCredentials {
        ExportCredentials(
            claude: loadCredentialFile(
                accounts: accounts,
                accountId: profile.claudeAccountId,
                relativePath: ".claude/.credentials.json"
            ),
            codex: loadCredentialFile(
                accounts: accounts,
                accountId: profile.codexAccountId,
                relativePath: ".codex/auth.json"
            ),
            gemini: loadCredentialFile(
                accounts: accounts,
                accountId: profile.geminiAccountId,
                relativePath: ".gemini/oauth_creds.json"
            )
        )
    }

    func loadCredentialFile(accounts: [UsageAccount], accountId: String?, relativePath: String) -> Data? {
        guard let accountId else { return nil }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return nil }

        let root = URL(fileURLWithPath: account.rootPath, isDirectory: true)
        let url = root.appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }

    func loadCurrentCredentialsFromHome() -> ExportCredentials {
        let home = homeDirectory

        func read(_ relativePath: String) -> Data? {
            let path = home.appendingPathComponent(relativePath)
            return try? Data(contentsOf: path)
        }

        return ExportCredentials(
            claude: read(".claude/.credentials.json"),
            codex: read(".codex/auth.json"),
            gemini: read(".gemini/oauth_creds.json")
        )
    }

    func resolveIdentities(credentials: ExportCredentials) async -> UsageIdentities {
        async let claudeProfileTask = resolveClaudeProfile(credentials: credentials.claude)
        let codexEmail = resolveJWTEmail(credentials: credentials.codex)
        let geminiEmail = resolveJWTEmail(credentials: credentials.gemini)
        let claudeProfile = await claudeProfileTask

        return UsageIdentities(
            claudeEmail: claudeProfile.email,
            claudeTier: claudeProfile.tier,
            claudeIsTeam: claudeProfile.isTeam,
            codexEmail: codexEmail,
            geminiEmail: geminiEmail
        )
    }

    struct ClaudeProfile: Sendable {
        let email: String?
        let tier: String?
        let isTeam: Bool?
    }

    struct ClaudeCredentialMetadata {
        let email: String?
        let tier: String?
        let isTeam: Bool?
    }

    func resolveClaudeProfile(credentials: Data?) async -> ClaudeProfile {
        let metadata = resolveClaudeCredentialMetadata(credentials: credentials)

        guard let token = extractClaudeAccessToken(credentials: credentials) else {
            return ClaudeProfile(
                email: metadata.email,
                tier: metadata.tier,
                isTeam: metadata.isTeam
            )
        }

        let profile = await fetchClaudeProfile(accessToken: token)
        return ClaudeProfile(
            email: profile.email ?? metadata.email,
            tier: profile.tier ?? metadata.tier,
            isTeam: profile.isTeam ?? metadata.isTeam
        )
    }

    func resolveClaudeCredentialMetadata(credentials: Data?) -> ClaudeCredentialMetadata {
        guard let credentials else {
            return ClaudeCredentialMetadata(email: nil, tier: nil, isTeam: nil)
        }

        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else {
            return ClaudeCredentialMetadata(email: nil, tier: nil, isTeam: nil)
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]

        let email: String? = {
            if let account = root["account"] as? [String: Any],
               let raw = account["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let account = oauth["account"] as? [String: Any],
               let raw = account["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let raw = root["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let raw = oauth["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            return nil
        }()

        let subscriptionType = normalizedString(oauth["subscriptionType"])
            ?? normalizedString(root["subscriptionType"])
        let rateLimitTier = normalizedString(oauth["rateLimitTier"])
            ?? normalizedString(root["rateLimitTier"])
        let tier = resolveClaudeTier(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
        let isTeam = resolveClaudeIsTeam(root: root, oauth: oauth, subscriptionType: subscriptionType)

        return ClaudeCredentialMetadata(email: email, tier: tier, isTeam: isTeam)
    }

    func resolveClaudeTier(subscriptionType: String?, rateLimitTier: String?) -> String? {
        if let rateLimitTier,
           let normalized = normalizeClaudeTier(string: rateLimitTier) {
            return normalized
        }

        guard let subscriptionType else { return nil }
        let lowered = subscriptionType.lowercased()
        if lowered.contains("pro") { return "Pro" }
        if lowered.contains("max") { return "Max" }
        return nil
    }

    func resolveClaudeIsTeam(root: [String: Any], oauth: [String: Any], subscriptionType: String?) -> Bool? {
        if let org = root["organization"] as? [String: Any],
           let orgType = org["organization_type"] as? String {
            return orgType.lowercased().contains("team")
        }

        if let org = oauth["organization"] as? [String: Any],
           let orgType = org["organization_type"] as? String {
            return orgType.lowercased().contains("team")
        }

        if let bool = parseBoolean(oauth["isTeam"]) ?? parseBoolean(root["isTeam"]) {
            return bool
        }

        if let subscriptionType {
            return subscriptionType.lowercased().contains("team")
        }

        return nil
    }

    // MARK: - Token Refresh

    func resolveTokenRefresh(credentials: ExportCredentials) -> UsageTokenRefresh {
        UsageTokenRefresh(
            claude: resolveClaudeTokenRefresh(credentials: credentials.claude),
            codex: resolveJWTTokenRefresh(credentials: credentials.codex, defaultLifetimeSeconds: 24 * 60 * 60),
            gemini: resolveGeminiTokenRefresh(credentials: credentials.gemini)
        )
    }

    func resolveClaudeTokenRefresh(credentials: Data?) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let expiresAt = parseDateFromAny(oauth["expiresAt"])
            ?? parseDateFromAny(oauth["expires_at"])
            ?? parseDateFromAny(oauth["expiresAtMs"])
            ?? parseDateFromAny(oauth["expires_at_ms"])
            ?? parseDateFromAny(oauth["expiresAtSeconds"])
            ?? parseDateFromAny(oauth["expires_at_seconds"])
            ?? parseDateFromAny(root["expiresAt"])
            ?? parseDateFromAny(root["expires_at"])

        if let expiresAt {
            let issuedAt = parseDateFromAny(oauth["issuedAt"])
                ?? parseDateFromAny(oauth["issued_at"])
                ?? parseDateFromAny(root["issuedAt"])
                ?? parseDateFromAny(root["issued_at"])

            let lifetime = computeLifetimeSeconds(
                expiresAt: expiresAt,
                issuedAt: issuedAt,
                defaultLifetimeSeconds: 60 * 60
            )
            return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
        }

        if let token = oauth["accessToken"] as? String {
            return decodeJWTPayloadTokenRefresh(fromToken: token, defaultLifetimeSeconds: 60 * 60)
        }

        return nil
    }

    func resolveJWTTokenRefresh(credentials: Data?, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }
        return findJWTTokenRefresh(in: root, defaultLifetimeSeconds: defaultLifetimeSeconds)
    }

    func resolveGeminiTokenRefresh(credentials: Data?) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }

        if let dict = root as? [String: Any] {
            let tokenDict = dict["token"] as? [String: Any] ?? [:]
            let expiresAt = parseDateFromAny(dict["expiry_date"])
                ?? parseDateFromAny(dict["expiryDate"])
                ?? parseDateFromAny(dict["expiresAt"])
                ?? parseDateFromAny(dict["expires_at"])
                ?? parseDateFromAny(tokenDict["expiresAt"])
                ?? parseDateFromAny(tokenDict["expiryDate"])
                ?? parseDateFromAny(tokenDict["expiry_date"])

            if let expiresAt {
                let issuedAt = parseDateFromAny(dict["issued_at"])
                    ?? parseDateFromAny(dict["issuedAt"])
                    ?? parseDateFromAny(tokenDict["issued_at"])
                    ?? parseDateFromAny(tokenDict["issuedAt"])

                let lifetime = computeLifetimeSeconds(
                    expiresAt: expiresAt,
                    issuedAt: issuedAt,
                    defaultLifetimeSeconds: 60 * 60
                )
                return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
            }
        }

        // Fallback: sometimes creds contain an ID token JWT with `exp`.
        return findJWTTokenRefresh(in: root, defaultLifetimeSeconds: 60 * 60)
    }

    func computeLifetimeSeconds(
        expiresAt: Date,
        issuedAt: Date?,
        defaultLifetimeSeconds: TimeInterval
    ) -> TimeInterval {
        guard let issuedAt else { return defaultLifetimeSeconds }
        let computed = expiresAt.timeIntervalSince(issuedAt)
        if computed.isFinite, computed > 0 { return computed }
        return defaultLifetimeSeconds
    }

    func parseDateFromAny(_ value: Any?) -> Date? {
        guard let value else { return nil }

        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return dateFromTimestamp(number.doubleValue) }
        if let double = value as? Double { return dateFromTimestamp(double) }
        if let int = value as? Int { return dateFromTimestamp(Double(int)) }

        if let string = value as? String {
            if let number = Double(string) {
                return dateFromTimestamp(number)
            }

            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
        }

        return nil
    }

    func dateFromTimestamp(_ timestamp: Double) -> Date? {
        guard timestamp.isFinite, timestamp > 0 else { return nil }

        if timestamp > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }

        if timestamp > 1_000_000_000 {
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }

    func findJWTTokenRefresh(in object: Any, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        if let value = object as? String {
            return decodeJWTPayloadTokenRefresh(fromToken: value, defaultLifetimeSeconds: defaultLifetimeSeconds)
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findJWTTokenRefresh(in: value, defaultLifetimeSeconds: defaultLifetimeSeconds) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findJWTTokenRefresh(in: value, defaultLifetimeSeconds: defaultLifetimeSeconds) { return found }
            }
        }

        return nil
    }

    func decodeJWTPayloadTokenRefresh(fromToken token: String, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let payloadBase64URL = String(parts[1])
        guard let payloadData = decodeBase64URL(payloadBase64URL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }

        guard let expSeconds = extractNumeric(root["exp"]) else { return nil }
        let expiresAt = Date(timeIntervalSince1970: expSeconds)

        let issuedAt: Date?
        if let iatSeconds = extractNumeric(root["iat"]) {
            issuedAt = Date(timeIntervalSince1970: iatSeconds)
        } else {
            issuedAt = nil
        }

        let lifetime = computeLifetimeSeconds(
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            defaultLifetimeSeconds: defaultLifetimeSeconds
        )
        return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
    }

    func extractNumeric(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parseBoolean(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = normalizedString(value) {
            let lowered = string.lowercased()
            if lowered == "true" || lowered == "1" || lowered == "yes" { return true }
            if lowered == "false" || lowered == "0" || lowered == "no" { return false }
            if lowered.contains("team") { return true }
        }
        return nil
    }

    func extractClaudeAccessToken(credentials: Data?) -> String? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    func fetchClaudeProfile(accessToken: String) async -> ClaudeProfile {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("agent-island", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
            }

            let email: String? = {
                if let account = root["account"] as? [String: Any] {
                    if let raw = account["email"] as? String, let extracted = extractEmailAddress(from: raw) {
                        return extracted
                    }
                }

                if let raw = root["email"] as? String, let extracted = extractEmailAddress(from: raw) {
                    return extracted
                }

                return findFirstEmailString(in: root)
            }()

            let isTeam: Bool? = {
                guard let org = root["organization"] as? [String: Any] else { return nil }
                guard let orgType = org["organization_type"] as? String else { return nil }
                return orgType.lowercased().contains("team")
            }()

            let tier = extractClaudeTier(in: root)
            return ClaudeProfile(email: email, tier: tier, isTeam: isTeam)
        } catch {
            return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
        }
    }

    func extractClaudeTier(in root: [String: Any]) -> String? {
        for key in ["subscriptionTier", "subscription_tier", "planType", "plan_type", "plan", "tier", "product", "sku"] {
            if let tier = parseClaudeTier(from: root[key]) { return tier }
        }

        for key in ["subscription", "billing", "entitlements", "account"] {
            if let tier = parseClaudeTier(from: root[key]) { return tier }
        }

        return nil
    }

    func parseClaudeTier(from value: Any?) -> String? {
        if let value, let number = extractNumeric(value) {
            if let tier = normalizeClaudeTier(multiplier: number) { return tier }
        }

        if let string = value as? String {
            return normalizeClaudeTier(string: string)
        }

        if let dict = value as? [String: Any] {
            for key in ["maxMultiplier", "max_multiplier", "maxTierMultiplier", "max_tier_multiplier", "multiplier"] {
                if let number = extractNumeric(dict[key]) {
                    if let tier = normalizeClaudeTier(multiplier: number) { return tier }
                }
            }

            for key in ["tier", "plan", "plan_type", "planType", "subscriptionTier", "subscription_tier", "product", "sku", "name", "id"] {
                if let tier = parseClaudeTier(from: dict[key]) { return tier }
            }

            for value in dict.values {
                if let tier = parseClaudeTier(from: value) { return tier }
            }
        }

        if let list = value as? [Any] {
            for value in list {
                if let tier = parseClaudeTier(from: value) { return tier }
            }
        }

        return nil
    }

    func normalizeClaudeTier(multiplier: Double) -> String? {
        if abs(multiplier - 20) < 0.01 { return "Max 20x" }
        if abs(multiplier - 5) < 0.01 { return "Max 5x" }
        return nil
    }

    func normalizeClaudeTier(string: String) -> String? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if raw.contains("@") { return nil }

        let lowered = raw.lowercased()
        let tokens = lowered.split { !($0.isLetter || $0.isNumber) }
        let hasToken: (String) -> Bool = { token in tokens.contains { $0 == token } }
        let normalized = lowered
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("max20") || (hasToken("max") && (hasToken("20x") || hasToken("20"))) { return "Max 20x" }
        if normalized.contains("max5") || (hasToken("max") && (hasToken("5x") || hasToken("5"))) { return "Max 5x" }
        if hasToken("pro") { return "Pro" }

        return nil
    }

    func resolveJWTEmail(credentials: Data?) -> String? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }
        return findJWTEmail(in: root)
    }

    func findJWTEmail(in object: Any) -> String? {
        if let value = object as? String {
            return decodeJWTPayloadEmail(fromToken: value)
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findJWTEmail(in: value) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findJWTEmail(in: value) { return found }
            }
        }

        return nil
    }

    func decodeJWTPayloadEmail(fromToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let payloadBase64URL = String(parts[1])
        guard let payloadData = decodeBase64URL(payloadBase64URL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }

        if let email = root["email"] as? String, let extracted = extractEmailAddress(from: email) { return extracted }
        if let email = root["preferred_username"] as? String, let extracted = extractEmailAddress(from: email) { return extracted }
        return findFirstEmailString(in: root)
    }

    func extractEmailAddress(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = Self.emailRegex.firstMatch(in: trimmed, options: [], range: nsRange) else { return nil }
        guard let range = Range(match.range, in: trimmed) else { return nil }
        return String(trimmed[range])
    }

    func findFirstEmailString(in object: Any) -> String? {
        if let value = object as? String, value.contains("@"), value.count < 200 {
            return extractEmailAddress(from: value)
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findFirstEmailString(in: value) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findFirstEmailString(in: value) { return found }
            }
        }

        return nil
    }

    private static let emailRegex: NSRegularExpression = {
        // Pragmatic: good-enough email substring matcher for provider identity extraction.
        let pattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        // Force unwrap: pattern is static and validated in development.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }
}

private final class UsageRefreshLogWriter {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let logFileURL: URL
    private let logDirURL: URL
    private let queue = DispatchQueue(label: "ai.2lab.agent-island.usage-refresh-log")
    private let maxLogBytes = 10 * 1024 * 1024
    private let maxRotatedFiles = 2

    init(homeDirectory: URL) {
        logDirURL = homeDirectory.appendingPathComponent(".agent-island/logs", isDirectory: true)
        logFileURL = logDirURL.appendingPathComponent("usage-refresh.log")
    }

    func write(event: String, fields: [String: String?]) {
        queue.async { [self] in
            do {
                try prepareLogFileIfNeeded()

                var payload: [String: String] = [
                    "timestamp": Self.iso8601Formatter.string(from: Date()),
                    "event": event,
                ]

                for (key, value) in fields {
                    guard let value else { continue }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    payload[key] = trimmed
                }

                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                guard let line = String(data: data, encoding: .utf8) else { return }
                try append(line: line)
            } catch {
                // Best-effort diagnostic logging only; never fail caller.
            }
        }
    }

    private func prepareLogFileIfNeeded() throws {
        try FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(
                atPath: logFileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if currentSize <= maxLogBytes { return }

        for i in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let older = logDirURL.appendingPathComponent("usage-refresh.log.\(i)")
            if i == maxRotatedFiles {
                try? FileManager.default.removeItem(at: older)
            } else {
                let newer = logDirURL.appendingPathComponent("usage-refresh.log.\(i + 1)")
                if FileManager.default.fileExists(atPath: older.path) {
                    try? FileManager.default.moveItem(at: older, to: newer)
                }
            }
        }
        let rotatedURL = logDirURL.appendingPathComponent("usage-refresh.log.1")
        try FileManager.default.moveItem(at: logFileURL, to: rotatedURL)
        FileManager.default.createFile(
            atPath: logFileURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func append(line: String) throws {
        guard let payload = "\(line)\n".data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: logFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }
}

private actor ClaudeRefreshLockRegistry {
    private var lockedKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ keys: [String]) async {
        for key in keys {
            await acquireSingle(key)
        }
    }

    func release(_ keys: [String]) {
        for key in keys.reversed() {
            releaseSingle(key)
        }
    }

    private func acquireSingle(_ key: String) async {
        if !lockedKeys.contains(key) {
            lockedKeys.insert(key)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func releaseSingle(_ key: String) {
        guard lockedKeys.contains(key) else { return }

        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            next.resume()
            return
        }

        lockedKeys.remove(key)
    }
}
