import CryptoKit
import Darwin
import Foundation

@main
struct CAuthCLI {
    static func main() async {
        do {
            let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
            let app = CAuthApp()
            switch command {
            case .help:
                app.printUsage()
            case .save(let profileName):
                try app.saveCurrentProfile(named: profileName)
            case .switchProfile(let profileName):
                try app.switchProfile(named: profileName)
            case .refresh:
                try await app.refreshAllProfiles()
            }
        } catch let error as CLIError {
            fputs("cauth: \(error.message)\n", stderr)
            exit(error.exitCode)
        } catch {
            fputs("cauth: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum Command {
    case help
    case save(String)
    case switchProfile(String)
    case refresh

    static func parse(_ args: [String]) throws -> Command {
        guard let first = args.first else { return .help }
        switch first {
        case "-h", "--help", "help":
            return .help
        case "save":
            guard args.count == 2 else {
                throw CLIError("usage: cauth save <profile-name>", exitCode: 2)
            }
            return .save(args[1])
        case "switch":
            guard args.count == 2 else {
                throw CLIError("usage: cauth switch <profile-name>", exitCode: 2)
            }
            return .switchProfile(args[1])
        case "refresh":
            guard args.count == 1 else {
                throw CLIError("usage: cauth refresh", exitCode: 2)
            }
            return .refresh
        default:
            throw CLIError("unknown command: \(first)", exitCode: 2)
        }
    }
}

private struct CLIError: Error {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

private enum UsageService: String, Codable {
    case claude
    case codex
    case gemini
}

private struct UsageAccount: Codable, Identifiable {
    let id: String
    let service: UsageService
    let label: String
    let rootPath: String
    let updatedAt: Date
}

private struct UsageProfile: Codable, Identifiable {
    let name: String
    let claudeAccountId: String?
    let codexAccountId: String?
    let geminiAccountId: String?

    var id: String { name }
}

private struct AccountsSnapshot: Codable {
    var accounts: [UsageAccount]
    var profiles: [UsageProfile]
}

private final class AccountStore {
    private let rootDir: URL
    private let fileManager: FileManager

    init(rootDir: URL, fileManager: FileManager = .default) {
        self.rootDir = rootDir
        self.fileManager = fileManager
    }

    private var fileURL: URL {
        rootDir.appendingPathComponent("accounts.json")
    }

    func loadSnapshot() throws -> AccountsSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AccountsSnapshot(accounts: [], profiles: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountsSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: AccountsSnapshot) throws {
        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private struct ClaudeCredentials {
    let root: [String: Any]
    let oauth: [String: Any]
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]
}

private struct RefreshResult {
    let credentialsData: Data
    let email: String?
    let plan: String?
    let keyRemaining: String
    let fiveHourPercent: Int?
    let fiveHourReset: Date?
    let sevenDayPercent: Int?
    let sevenDayReset: Date?
}

struct UsageSummary {
    let fiveHourPercent: Int?
    let fiveHourReset: Date?
    let sevenDayPercent: Int?
    let sevenDayReset: Date?
}

struct ClaudeRefreshPayload {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let scope: String?
}

struct ProcessExecutionResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

typealias CAuthProcessRunner = (_ executable: String, _ arguments: [String]) -> ProcessExecutionResult
typealias ClaudeTokenRefreshClient = @Sendable (_ refreshToken: String, _ scope: String) async throws -> ClaudeRefreshPayload
typealias ClaudeUsageClient = @Sendable (_ accessToken: String) async -> UsageSummary?

final class CAuthApp {
    private let fileManager: FileManager
    private let homeDir: URL
    private let agentRoot: URL
    private let accountsDir: URL
    private let accountStore: AccountStore
    private let keychainServiceName: String
    private let claudeOAuthClientID: String
    private let claudeTokenEndpoint: URL
    private let claudeUsageEndpoint: URL
    private let securityExecutable: String
    private let processRunner: CAuthProcessRunner
    private let tokenRefreshClient: ClaudeTokenRefreshClient
    private let usageClient: ClaudeUsageClient
    private let claudeDefaultScope = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
    private let lockDirName = "locks"

    init(
        fileManager: FileManager = .default,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainServiceName: String = "Claude Code-credentials",
        claudeOAuthClientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        claudeTokenEndpoint: URL? = nil,
        claudeUsageEndpoint: URL? = nil,
        securityExecutable: String? = nil,
        processRunner: @escaping CAuthProcessRunner = CAuthApp.defaultProcessRunner,
        tokenRefreshClient: ClaudeTokenRefreshClient? = nil,
        usageClient: ClaudeUsageClient? = nil
    ) {
        let env = ProcessInfo.processInfo.environment
        let resolvedTokenEndpoint = claudeTokenEndpoint
            ?? URL(string: env["CLAUDE_CODE_TOKEN_URL"] ?? "https://platform.claude.com/v1/oauth/token")!
        let resolvedUsageEndpoint = claudeUsageEndpoint
            ?? URL(string: env["CLAUDE_CODE_USAGE_URL"] ?? "https://api.anthropic.com/api/oauth/usage")!
        let resolvedSecurityExecutable = securityExecutable
            ?? env["CAUTH_SECURITY_BIN"]
            ?? "/usr/bin/security"

        self.fileManager = fileManager
        self.homeDir = homeDir
        self.agentRoot = homeDir.appendingPathComponent(".agent-island", isDirectory: true)
        self.accountsDir = agentRoot.appendingPathComponent("accounts", isDirectory: true)
        self.accountStore = AccountStore(rootDir: agentRoot, fileManager: fileManager)
        self.keychainServiceName = keychainServiceName
        self.claudeOAuthClientID = claudeOAuthClientID
        self.claudeTokenEndpoint = resolvedTokenEndpoint
        self.claudeUsageEndpoint = resolvedUsageEndpoint
        self.securityExecutable = resolvedSecurityExecutable
        self.processRunner = processRunner
        self.tokenRefreshClient = tokenRefreshClient ?? { refreshToken, scope in
            try await CAuthApp.defaultTokenRefresh(
                tokenEndpoint: resolvedTokenEndpoint,
                oauthClientID: claudeOAuthClientID,
                refreshToken: refreshToken,
                scope: scope
            )
        }
        self.usageClient = usageClient ?? { accessToken in
            await CAuthApp.defaultUsageFetch(
                usageEndpoint: resolvedUsageEndpoint,
                accessToken: accessToken
            )
        }
    }

    func printUsage() {
        let text = """
        cauth - Claude auth profile CLI

        Usage:
          cauth save <profile-name>      Save current Claude auth into named profile
          cauth switch <profile-name>    Switch active Claude auth to named profile
          cauth refresh                  Refresh all saved Claude profiles and print usage
          cauth help                     Show this help
        """
        print(text)
    }

    func saveCurrentProfile(named profileName: String) throws {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CLIError("profile name is required") }

        guard let credentialData = loadCurrentClaudeCredentials() else {
            throw CLIError("current Claude credentials not found in ~/.claude/.credentials.json or keychain")
        }

        let accountId = resolveClaudeAccountID(from: credentialData)
        let accountRoot = accountsDir.appendingPathComponent(accountId, isDirectory: true)
        let accountCredentialPath = accountRoot.appendingPathComponent(".claude/.credentials.json")
        try writeCredentialDataAtomically(credentialData, to: accountCredentialPath)

        var snapshot = try accountStore.loadSnapshot()
        let hashPrefix = shortHashHex(credentialData)
        let account = UsageAccount(
            id: accountId,
            service: .claude,
            label: "claude:\(hashPrefix)",
            rootPath: accountRoot.path,
            updatedAt: Date()
        )
        upsertAccount(account, into: &snapshot)

        let existing = snapshot.profiles.first { $0.name == name }
        let profile = UsageProfile(
            name: name,
            claudeAccountId: accountId,
            codexAccountId: existing?.codexAccountId,
            geminiAccountId: existing?.geminiAccountId
        )
        upsertProfile(profile, into: &snapshot)
        try accountStore.saveSnapshot(snapshot)

        let parsed = parseClaudeCredentials(from: credentialData)
        let email = extractClaudeEmail(from: parsed.root) ?? "-"
        let plan = resolveClaudePlan(from: parsed.root) ?? "-"
        print("saved profile \(name): \(email) \(plan) -> \(accountId)")
    }

    func switchProfile(named profileName: String) throws {
        let snapshot = try accountStore.loadSnapshot()
        guard let profile = snapshot.profiles.first(where: { $0.name == profileName }) else {
            throw CLIError("profile not found: \(profileName)")
        }
        guard let accountId = profile.claudeAccountId else {
            throw CLIError("profile has no Claude account: \(profileName)")
        }
        guard let account = snapshot.accounts.first(where: { $0.id == accountId && $0.service == .claude }) else {
            throw CLIError("Claude account not found for profile: \(profileName)")
        }

        let sourcePath = URL(fileURLWithPath: account.rootPath, isDirectory: true)
            .appendingPathComponent(".claude/.credentials.json")
        guard fileManager.fileExists(atPath: sourcePath.path) else {
            throw CLIError("missing stored credentials: \(sourcePath.path)")
        }

        let data = try Data(contentsOf: sourcePath)
        let activePath = homeDir.appendingPathComponent(".claude/.credentials.json")
        try writeCredentialDataAtomically(data, to: activePath)
        try saveClaudeCredentialsToKeychain(data: data)

        let parsed = parseClaudeCredentials(from: data)
        let email = extractClaudeEmail(from: parsed.root) ?? "-"
        let plan = resolveClaudePlan(from: parsed.root) ?? "-"
        print("switched profile \(profileName): \(email) \(plan)")
    }

    func refreshAllProfiles() async throws {
        var snapshot = try accountStore.loadSnapshot()
        let profiles = snapshot.profiles.sorted { $0.name < $1.name }
        if profiles.isEmpty {
            print("no profiles")
            return
        }

        let accountById = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0) })
        let activeData = loadCurrentClaudeCredentials()
        let activeAccountID = activeData.map(resolveClaudeAccountID(from:))

        var refreshedByAccountID: [String: RefreshResult] = [:]
        var refreshedByLockID: [String: RefreshResult] = [:]
        var touchedAccountIDs: Set<String> = []

        for profile in profiles {
            guard let accountId = profile.claudeAccountId else { continue }
            guard let account = accountById[accountId], account.service == .claude else { continue }
            guard refreshedByAccountID[accountId] == nil else { continue }

            let accountRoot = URL(fileURLWithPath: account.rootPath, isDirectory: true)
            let credentialPath = accountRoot.appendingPathComponent(".claude/.credentials.json")
            guard fileManager.fileExists(atPath: credentialPath.path) else { continue }

            let currentData = try Data(contentsOf: credentialPath)
            let lockID = resolveRefreshLockID(from: currentData, fallback: accountId)
            if let existing = refreshedByLockID[lockID] {
                try writeCredentialDataAtomically(existing.credentialsData, to: credentialPath)
                if activeAccountID == accountId {
                    let activePath = homeDir.appendingPathComponent(".claude/.credentials.json")
                    try writeCredentialDataAtomically(existing.credentialsData, to: activePath)
                    try saveClaudeCredentialsToKeychain(data: existing.credentialsData)
                }
                refreshedByAccountID[accountId] = existing
                touchedAccountIDs.insert(accountId)
                continue
            }

            let refreshedData = try await withRefreshLock(lockID: lockID) {
                try await refreshClaudeCredentialsAlways(currentData)
            }
            try writeCredentialDataAtomically(refreshedData, to: credentialPath)

            if activeAccountID == accountId {
                let activePath = homeDir.appendingPathComponent(".claude/.credentials.json")
                try writeCredentialDataAtomically(refreshedData, to: activePath)
                try saveClaudeCredentialsToKeychain(data: refreshedData)
            }

            let parsed = parseClaudeCredentials(from: refreshedData)
            let plan = resolveClaudePlan(from: parsed.root)
            let email = extractClaudeEmail(from: parsed.root)
            let keyRemaining = formatKeyRemaining(expiresAt: parsed.expiresAt)
            let usage = await fetchClaudeUsageSummary(accessToken: parsed.accessToken)
            let result = RefreshResult(
                credentialsData: refreshedData,
                email: email,
                plan: plan,
                keyRemaining: keyRemaining,
                fiveHourPercent: usage?.fiveHourPercent,
                fiveHourReset: usage?.fiveHourReset,
                sevenDayPercent: usage?.sevenDayPercent,
                sevenDayReset: usage?.sevenDayReset
            )
            refreshedByLockID[lockID] = result
            refreshedByAccountID[accountId] = result
            touchedAccountIDs.insert(accountId)
        }

        for id in touchedAccountIDs {
            guard let idx = snapshot.accounts.firstIndex(where: { $0.id == id }) else { continue }
            let updated = UsageAccount(
                id: snapshot.accounts[idx].id,
                service: snapshot.accounts[idx].service,
                label: snapshot.accounts[idx].label,
                rootPath: snapshot.accounts[idx].rootPath,
                updatedAt: Date()
            )
            snapshot.accounts[idx] = updated
        }
        try accountStore.saveSnapshot(snapshot)

        for profile in profiles {
            guard let accountId = profile.claudeAccountId else {
                print("\(profile.name): - - 5h -- 7d -- (key) --")
                continue
            }
            guard let refreshed = refreshedByAccountID[accountId] else {
                print("\(profile.name): - - 5h -- 7d -- (key) --")
                continue
            }

            let email = refreshed.email ?? "-"
            let plan = refreshed.plan ?? "-"
            let five = formatUsageWindow(percent: refreshed.fiveHourPercent, resetAt: refreshed.fiveHourReset)
            let seven = formatUsageWindow(percent: refreshed.sevenDayPercent, resetAt: refreshed.sevenDayReset)
            print("\(profile.name): \(email) \(plan) 5h \(five) 7d \(seven) (key) \(refreshed.keyRemaining)")
        }
    }

    private func loadCurrentClaudeCredentials() -> Data? {
        let activePath = homeDir.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: activePath) {
            return data
        }
        if let keychain = readKeychain(service: keychainServiceName) {
            return Data(keychain.utf8)
        }
        return nil
    }

    private func upsertAccount(_ account: UsageAccount, into snapshot: inout AccountsSnapshot) {
        if let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) {
            snapshot.accounts[index] = account
        } else {
            snapshot.accounts.append(account)
        }
    }

    private func upsertProfile(_ profile: UsageProfile, into snapshot: inout AccountsSnapshot) {
        if let index = snapshot.profiles.firstIndex(where: { $0.name == profile.name }) {
            snapshot.profiles[index] = profile
        } else {
            snapshot.profiles.append(profile)
        }
    }

    private func writeCredentialDataAtomically(_ data: Data, to fileURL: URL) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func parseClaudeCredentials(from data: Data) -> ClaudeCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any]
        else {
            return ClaudeCredentials(root: [:], oauth: [:], accessToken: nil, refreshToken: nil, expiresAt: nil, scopes: [])
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let accessToken = normalizedString(oauth["accessToken"])
        let refreshToken = normalizedString(oauth["refreshToken"])
        let expiresAt = parseDateFromAny(oauth["expiresAt"])
            ?? parseDateFromAny(oauth["expires_at"])
            ?? parseDateFromAny(root["expiresAt"])
            ?? parseDateFromAny(root["expires_at"])
        let scopes = normalizeScopes(oauth["scopes"])
        return ClaudeCredentials(
            root: root,
            oauth: oauth,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }

    private func normalizeScopes(_ value: Any?) -> [String] {
        if let list = value as? [String] {
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let string = value as? String {
            return string
                .split(separator: " ")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func parseDateFromAny(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let date = value as? Date { return date }
        if let int = value as? Int { return dateFromTimestamp(Double(int)) }
        if let num = value as? NSNumber { return dateFromTimestamp(num.doubleValue) }
        if let string = value as? String {
            if let num = Double(string) {
                return dateFromTimestamp(num)
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: string)
        }
        return nil
    }

    private func dateFromTimestamp(_ timestamp: Double) -> Date? {
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        if timestamp > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }
        if timestamp > 1_000_000_000 {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    private func resolveClaudeAccountID(from data: Data) -> String {
        let parsed = parseClaudeCredentials(from: data)
        if let email = extractClaudeEmail(from: parsed.root),
           let slug = emailSlug(email) {
            if resolveClaudeIsTeam(from: parsed.root) == true {
                return "acct_claude_team_\(slug)"
            }
            return "acct_claude_\(slug)"
        }

        let refreshToken = parsed.refreshToken ?? "-"
        let stable = "claude:refresh:\(refreshToken)"
        return "acct_claude_\(shortHashHex(Data(stable.utf8)))"
    }

    private func extractClaudeEmail(from root: [String: Any]) -> String? {
        if let email = normalizedEmail(root["email"] as? String) { return email }
        if let account = root["account"] as? [String: Any],
           let email = normalizedEmail(account["email"] as? String) {
            return email
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        if let email = normalizedEmail(oauth["email"] as? String) { return email }
        if let account = oauth["account"] as? [String: Any],
           let email = normalizedEmail(account["email"] as? String) {
            return email
        }
        if let token = normalizedString(oauth["accessToken"]),
           let email = decodeJWTEmail(from: token) {
            return email
        }
        return nil
    }

    private func resolveClaudePlan(from root: [String: Any]) -> String? {
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let subscriptionType = normalizedString(oauth["subscriptionType"]) ?? normalizedString(root["subscriptionType"])
        let rateLimitTier = normalizedString(oauth["rateLimitTier"]) ?? normalizedString(root["rateLimitTier"])

        if let tier = rateLimitTier?.lowercased() {
            if tier.contains("max") && tier.contains("20") { return "Max 20x" }
            if tier.contains("max") && tier.contains("5") { return "Max 5x" }
            if tier.contains("pro") { return "Pro" }
            if tier.contains("max") { return "Max" }
        }
        if let type = subscriptionType?.lowercased() {
            if type.contains("max") && type.contains("20") { return "Max 20x" }
            if type.contains("max") && type.contains("5") { return "Max 5x" }
            if type.contains("pro") { return "Pro" }
            if type.contains("max") { return "Max" }
        }
        return nil
    }

    private func resolveClaudeIsTeam(from root: [String: Any]) -> Bool? {
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        if let value = parseBoolean(oauth["isTeam"]) { return value }
        if let value = parseBoolean(root["isTeam"]) { return value }
        if let type = normalizedString(oauth["subscriptionType"])?.lowercased(), type.contains("team") { return true }
        if let type = normalizedString(root["subscriptionType"])?.lowercased(), type.contains("team") { return true }
        if let organization = oauth["organization"] as? [String: Any],
           let orgType = normalizedString(organization["organization_type"])?.lowercased(),
           orgType.contains("team") {
            return true
        }
        if let organization = root["organization"] as? [String: Any],
           let orgType = normalizedString(organization["organization_type"])?.lowercased(),
           orgType.contains("team") {
            return true
        }
        return nil
    }

    private func parseBoolean(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let num = value as? NSNumber { return num.boolValue }
        if let string = normalizedString(value)?.lowercased() {
            if string == "true" || string == "1" { return true }
            if string == "false" || string == "0" { return false }
            if string.contains("team") { return true }
        }
        return nil
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.contains("@") else { return nil }
        return trimmed
    }

    private func decodeJWTEmail(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let payload = decodeBase64URL(String(parts[1])) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let email = normalizedEmail(root["email"] as? String) { return email }
        if let email = normalizedEmail(root["preferred_username"] as? String) { return email }
        return nil
    }

    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private func emailSlug(_ email: String) -> String? {
        let lowered = email.lowercased()
        var output: [UInt8] = []
        var lastUnderscore = false
        for byte in lowered.utf8 {
            let isDigit = byte >= 48 && byte <= 57
            let isLower = byte >= 97 && byte <= 122
            if isDigit || isLower {
                output.append(byte)
                lastUnderscore = false
                continue
            }
            if !lastUnderscore {
                output.append(95)
                lastUnderscore = true
            }
        }
        let raw = String(decoding: output, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return raw.isEmpty ? nil : raw
    }

    private func shortHashHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func resolveRefreshLockID(from data: Data, fallback: String) -> String {
        let parsed = parseClaudeCredentials(from: data)
        guard let refreshToken = parsed.refreshToken else {
            return fallback
        }
        return shortHashHex(Data(refreshToken.utf8))
    }

    private func withRefreshLock<T>(lockID: String, operation: () async throws -> T) async throws -> T {
        let lockPath = agentRoot
            .appendingPathComponent(lockDirName, isDirectory: true)
            .appendingPathComponent("cauth-refresh-\(lockID).lock")
        let lock = try FileLock(filePath: lockPath.path)
        defer { lock.unlock() }
        return try await operation()
    }

    private func refreshClaudeCredentialsAlways(_ data: Data) async throws -> Data {
        var parsed = parseClaudeCredentials(from: data)
        guard let refreshToken = parsed.refreshToken else {
            throw CLIError("missing refresh token in stored credentials")
        }

        let scope = parsed.scopes.isEmpty ? claudeDefaultScope : parsed.scopes.joined(separator: " ")
        let refreshed = try await tokenRefreshClient(refreshToken, scope)
        let newAccessToken = refreshed.accessToken
        let newRefreshToken = refreshed.refreshToken ?? refreshToken
        let expiresIn = refreshed.expiresIn
        let nowMillis = Date().timeIntervalSince1970 * 1000
        let newExpiresAt = expiresIn.map { Int(nowMillis + ($0 * 1000)) }

        var root = parsed.root
        var oauth = parsed.oauth
        oauth["accessToken"] = newAccessToken
        oauth["refreshToken"] = newRefreshToken
        if let newExpiresAt {
            oauth["expiresAt"] = newExpiresAt
        }
        if let scopeString = normalizedString(refreshed.scope) {
            oauth["scopes"] = normalizeScopes(scopeString)
        }
        root["claudeAiOauth"] = oauth
        parsed = parseClaudeCredentials(from: try JSONSerialization.data(withJSONObject: root, options: []))
        return try JSONSerialization.data(withJSONObject: parsed.root, options: [.prettyPrinted, .sortedKeys])
    }

    private func fetchClaudeUsageSummary(accessToken: String?) async -> UsageSummary? {
        guard let accessToken else { return nil }
        return await usageClient(accessToken)
    }

    private func formatUsageWindow(percent: Int?, resetAt: Date?) -> String {
        let percentString = percent.map { "\($0)%" } ?? "--"
        let resetString = resetAt.map(formatTimeRemaining(until:)) ?? "--"
        return "\(percentString) (\(resetString))"
    }

    private func formatTimeRemaining(until date: Date) -> String {
        let remaining = Int(date.timeIntervalSinceNow.rounded())
        if remaining <= 0 { return "expired" }
        return formatDuration(seconds: remaining)
    }

    private func formatKeyRemaining(expiresAt: Date?) -> String {
        guard let expiresAt else { return "--" }
        let remaining = Int(expiresAt.timeIntervalSinceNow.rounded())
        if remaining <= 0 { return "expired" }
        return formatDuration(seconds: remaining)
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        return "\(hours)h \(minutes)m"
    }

    private func readKeychain(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account {
            args.append(contentsOf: ["-a", account])
        }
        args.append("-w")
        let result = processRunner(securityExecutable, args)
        guard result.status == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveClaudeCredentialsToKeychain(data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CLIError("credentials are not valid UTF-8 JSON")
        }
        let accountName = resolveClaudeKeychainAccountName()
            ?? ProcessInfo.processInfo.environment["USER"]
            ?? "default"
        let result = processRunner(
            securityExecutable,
            [
                "add-generic-password",
                "-a", accountName,
                "-s", keychainServiceName,
                "-w", raw,
                "-U",
            ]
        )
        guard result.status == 0 else {
            throw CLIError("failed to update keychain: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func resolveClaudeKeychainAccountName() -> String? {
        let result = processRunner(
            securityExecutable,
            ["find-generic-password", "-s", keychainServiceName, "-g"]
        )
        guard result.status == 0 else { return nil }
        let target = result.stderr
        guard let range = target.range(of: "\"acct\"<blob>=\"") else { return nil }
        let start = range.upperBound
        guard let end = target[start...].firstIndex(of: "\"") else { return nil }
        let account = String(target[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? nil : account
    }

    private static func defaultProcessRunner(executable: String, arguments: [String]) -> ProcessExecutionResult {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessExecutionResult(status: 1, stdout: "", stderr: String(describing: error))
        }
        let outString = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errString = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessExecutionResult(
            status: process.terminationStatus,
            stdout: outString,
            stderr: errString
        )
    }

    private static func defaultTokenRefresh(
        tokenEndpoint: URL,
        oauthClientID: String,
        refreshToken: String,
        scope: String
    ) async throws -> ClaudeRefreshPayload {
        let payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": scope,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payloadData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIError("invalid token refresh response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CLIError("refresh failed (\(http.statusCode)): \(body.prefix(200))")
        }
        guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw CLIError("refresh response is not JSON object")
        }
        guard let accessToken = normalizeStringFromAny(root["access_token"]) else {
            throw CLIError("refresh response missing access_token")
        }
        let refreshedToken = normalizeStringFromAny(root["refresh_token"])
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue
        let scopeValue = normalizeStringFromAny(root["scope"])
        return ClaudeRefreshPayload(
            accessToken: accessToken,
            refreshToken: refreshedToken,
            expiresIn: expiresIn,
            scope: scopeValue
        )
    }

    private static func defaultUsageFetch(usageEndpoint: URL, accessToken: String) async -> UsageSummary? {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("cauth/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let five = parseUsageWindowFromAny(root["five_hour"])
            let seven = parseUsageWindowFromAny(root["seven_day"])
            return UsageSummary(
                fiveHourPercent: five.percent,
                fiveHourReset: five.resetAt,
                sevenDayPercent: seven.percent,
                sevenDayReset: seven.resetAt
            )
        } catch {
            return nil
        }
    }

    private static func parseUsageWindowFromAny(_ value: Any?) -> (percent: Int?, resetAt: Date?) {
        guard let window = value as? [String: Any] else { return (nil, nil) }
        let utilizationValue = (window["utilization"] as? NSNumber)?.doubleValue
        let percent = utilizationValue.map { Int($0.rounded()) }
        let resetAt = parseDateFromAnyValue(window["resets_at"])
        return (percent, resetAt)
    }

    private static func parseDateFromAnyValue(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let date = value as? Date { return date }
        if let int = value as? Int { return dateFromTimestampValue(Double(int)) }
        if let num = value as? NSNumber { return dateFromTimestampValue(num.doubleValue) }
        if let string = value as? String {
            if let num = Double(string) {
                return dateFromTimestampValue(num)
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: string)
        }
        return nil
    }

    private static func dateFromTimestampValue(_ timestamp: Double) -> Date? {
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        if timestamp > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }
        if timestamp > 1_000_000_000 {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    private static func normalizeStringFromAny(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class FileLock {
    private let fd: Int32

    init(filePath: String) throws {
        let lockURL = URL(fileURLWithPath: filePath)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(filePath, O_CREAT | O_RDWR, 0o600)
        if fd == -1 {
            throw CLIError("failed to open lock file: \(filePath)")
        }
        if flock(fd, LOCK_EX) != 0 {
            close(fd)
            throw CLIError("failed to acquire lock: \(filePath)")
        }
    }

    func unlock() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
