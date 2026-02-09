import Foundation

@main
enum ProfileSwitcherTests {
    static func main() throws {
        try testStableFingerprintForClaudeRefreshToken()
        try testStableFingerprintForCodexAccountID()
        try testSaveProfileSkipsIncompleteCodexCredentials()
        try testSwitchToProfileBackfillsMissingCodexIDToken()
        try testMigrateStoredClaudeAccountsToCanonicalIDs()

        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp/claude-island-profile-switcher-home", isDirectory: true)
        if fm.fileExists(atPath: home.path) {
            try fm.removeItem(at: home)
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let accountRoot = home.appendingPathComponent(".claude-island", isDirectory: true)
        let store = AccountStore(rootDir: accountRoot)
        let switcher = ProfileSwitcher(accountStore: store, exporter: CredentialExporter(), activeHomeDir: home)

        let claudeCreds = Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\"}}".utf8)
        let codexCreds = try makeCodexCredential(
            accessToken: "tok",
            accountId: "acct",
            idToken: "id-token",
            refreshToken: "refresh-token"
        )
        let geminiCreds = Data("{\"access_token\":\"tok\"}".utf8)

        let save = try switcher.saveProfile(
            named: "A",
            credentials: ExportCredentials(claude: claudeCreds, codex: codexCreds, gemini: geminiCreds)
        )
        assert(save.profile.name == "A")
        assert(save.profile.claudeAccountId != nil)
        assert(save.profile.codexAccountId != nil)
        assert(save.profile.geminiAccountId != nil)

        let snapshot = try store.loadSnapshot()
        assert(snapshot.profiles.count == 1)
        assert(snapshot.accounts.count == 3)

        for account in snapshot.accounts {
            let root = URL(fileURLWithPath: account.rootPath, isDirectory: true)
            assert(fm.fileExists(atPath: root.path))
        }

        let switched = try switcher.switchToProfile(save.profile)
        assert(switched.profileName == "A")
        assert(switched.claudeSwitched)
        assert(switched.codexSwitched)
        assert(switched.geminiSwitched)

        let activeClaude = home.appendingPathComponent(".claude/.credentials.json")
        let activeCodex = home.appendingPathComponent(".codex/auth.json")
        let activeGemini = home.appendingPathComponent(".gemini/oauth_creds.json")
        assert(fm.fileExists(atPath: activeClaude.path))
        assert(fm.fileExists(atPath: activeCodex.path))
        assert(fm.fileExists(atPath: activeGemini.path))

        let activeClaudeData = try Data(contentsOf: activeClaude)
        let activeCodexData = try Data(contentsOf: activeCodex)
        let activeGeminiData = try Data(contentsOf: activeGemini)
        assert(activeClaudeData == claudeCreds)
        assert(activeCodexData == codexCreds)
        assert(activeGeminiData == geminiCreds)

        print("OK")
    }

    private static func testStableFingerprintForClaudeRefreshToken() throws {
        let first = Data("""
        {"claudeAiOauth":{"accessToken":"at-1","refreshToken":"rt-stable","expiresAt":1735689600000}}
        """.utf8)
        let second = Data("""
        {"claudeAiOauth":{"accessToken":"at-2","refreshToken":"rt-stable","expiresAt":1735693200000}}
        """.utf8)
        let third = Data("""
        {"claudeAiOauth":{"accessToken":"at-3","refreshToken":"rt-rotated","expiresAt":1735696800000}}
        """.utf8)

        let firstID = UsageCredentialHasher.fingerprint(service: .claude, data: first).accountId
        let secondID = UsageCredentialHasher.fingerprint(service: .claude, data: second).accountId
        let thirdID = UsageCredentialHasher.fingerprint(service: .claude, data: third).accountId

        assert(firstID == secondID)
        assert(firstID != thirdID)
    }

    private static func testStableFingerprintForCodexAccountID() throws {
        let first = Data("""
        {"tokens":{"access_token":"tok-a","account_id":"acct-user-1"}}
        """.utf8)
        let second = Data("""
        {"tokens":{"access_token":"tok-b","account_id":"acct-user-1"}}
        """.utf8)
        let third = Data("""
        {"tokens":{"access_token":"tok-c","account_id":"acct-user-2"}}
        """.utf8)

        let firstID = UsageCredentialHasher.fingerprint(service: .codex, data: first).accountId
        let secondID = UsageCredentialHasher.fingerprint(service: .codex, data: second).accountId
        let thirdID = UsageCredentialHasher.fingerprint(service: .codex, data: third).accountId

        assert(firstID == secondID)
        assert(firstID != thirdID)
    }

    private static func testSaveProfileSkipsIncompleteCodexCredentials() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp/claude-island-profile-switcher-incomplete-codex", isDirectory: true)
        if fm.fileExists(atPath: home.path) {
            try fm.removeItem(at: home)
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let store = AccountStore(rootDir: home.appendingPathComponent(".agent-island", isDirectory: true))
        let switcher = ProfileSwitcher(accountStore: store, exporter: CredentialExporter(), activeHomeDir: home)

        let incompleteCodex = try makeCodexCredential(
            accessToken: "tok",
            accountId: "acct",
            idToken: nil,
            refreshToken: "refresh-token"
        )
        let save = try switcher.saveProfile(
            named: "broken-codex",
            credentials: ExportCredentials(claude: nil, codex: incompleteCodex, gemini: nil)
        )

        assert(save.profile.codexAccountId == nil)
        assert(save.warnings.contains { $0.contains("Codex credentials incomplete") })
    }

    private static func testSwitchToProfileBackfillsMissingCodexIDToken() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp/claude-island-profile-switcher-codex-merge", isDirectory: true)
        if fm.fileExists(atPath: home.path) {
            try fm.removeItem(at: home)
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let store = AccountStore(rootDir: home.appendingPathComponent(".agent-island", isDirectory: true))
        let switcher = ProfileSwitcher(accountStore: store, exporter: CredentialExporter(), activeHomeDir: home)

        let completeCodex = try makeCodexCredential(
            accessToken: "tok-old",
            accountId: "acct-same",
            idToken: "id-stable",
            refreshToken: "refresh-stable"
        )
        let save = try switcher.saveProfile(
            named: "merge-codex",
            credentials: ExportCredentials(claude: nil, codex: completeCodex, gemini: nil)
        )
        guard let codexAccountId = save.profile.codexAccountId else {
            assertionFailure("Expected codex account id")
            return
        }

        let firstSwitch = try switcher.switchToProfile(save.profile)
        assert(firstSwitch.codexSwitched)

        let accountCodexPath = home
            .appendingPathComponent(".agent-island/accounts", isDirectory: true)
            .appendingPathComponent(codexAccountId, isDirectory: true)
            .appendingPathComponent(".codex/auth.json")

        let incompleteCodex = try makeCodexCredential(
            accessToken: "tok-new",
            accountId: "acct-same",
            idToken: nil,
            refreshToken: nil
        )
        try incompleteCodex.write(to: accountCodexPath, options: [.atomic])

        let secondSwitch = try switcher.switchToProfile(save.profile)
        assert(secondSwitch.codexSwitched)

        let activeCodexPath = home.appendingPathComponent(".codex/auth.json")
        let activeTokens = try parseCodexTokens(from: Data(contentsOf: activeCodexPath))
        assert(activeTokens["access_token"] as? String == "tok-new")
        assert(activeTokens["account_id"] as? String == "acct-same")
        assert(activeTokens["id_token"] as? String == "id-stable")
        assert(activeTokens["refresh_token"] as? String == "refresh-stable")
    }

    private static func testMigrateStoredClaudeAccountsToCanonicalIDs() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp/claude-island-profile-switcher-claude-migrate", isDirectory: true)
        if fm.fileExists(atPath: home.path) {
            try fm.removeItem(at: home)
        }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let root = home.appendingPathComponent(".agent-island", isDirectory: true)
        let accountsDir = root.appendingPathComponent("accounts", isDirectory: true)
        try fm.createDirectory(at: accountsDir, withIntermediateDirectories: true)

        let store = AccountStore(rootDir: root)
        let switcher = ProfileSwitcher(accountStore: store, exporter: CredentialExporter(), activeHomeDir: home)

        let oldA = "acct_claude_old_a"
        let oldB = "acct_claude_old_b"
        let canonical = "acct_claude_z_insightquest_io"

        let oldARoot = accountsDir.appendingPathComponent(oldA, isDirectory: true)
        let oldBRoot = accountsDir.appendingPathComponent(oldB, isDirectory: true)
        try fm.createDirectory(at: oldARoot.appendingPathComponent(".claude", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: oldBRoot.appendingPathComponent(".claude", isDirectory: true), withIntermediateDirectories: true)

        let oldACreds = Data("{\"claudeAiOauth\":{\"accessToken\":\"at-a\",\"refreshToken\":\"rt-a\"}}".utf8)
        let oldBCreds = Data("{\"claudeAiOauth\":{\"accessToken\":\"at-b\",\"refreshToken\":\"rt-b\"}}".utf8)
        try oldACreds.write(to: oldARoot.appendingPathComponent(".claude/.credentials.json"), options: [.atomic])
        try oldBCreds.write(to: oldBRoot.appendingPathComponent(".claude/.credentials.json"), options: [.atomic])

        let now = Date()
        let snapshot = AccountsSnapshot(
            accounts: [
                UsageAccount(
                    id: oldA,
                    service: .claude,
                    label: "claude:a",
                    rootPath: oldARoot.path,
                    updatedAt: now.addingTimeInterval(-100)
                ),
                UsageAccount(
                    id: oldB,
                    service: .claude,
                    label: "claude:b",
                    rootPath: oldBRoot.path,
                    updatedAt: now
                ),
            ],
            profiles: [
                UsageProfile(name: "home", claudeAccountId: oldA, codexAccountId: nil, geminiAccountId: nil),
                UsageProfile(name: "work", claudeAccountId: oldB, codexAccountId: nil, geminiAccountId: nil),
            ]
        )
        try store.saveSnapshot(snapshot)

        let identities = """
        {
          "\(oldA)": { "email": "z@insightquest.io", "claudeIsTeam": false },
          "\(oldB)": { "email": " z@insightquest.io ", "claudeIsTeam": false }
        }
        """
        try Data(identities.utf8).write(to: root.appendingPathComponent("usage-identities.json"), options: [.atomic])

        let tokens = """
        {
          "\(oldA)": { "token": "token-a", "enabled": true },
          "\(oldB)": { "token": "token-b", "enabled": true }
        }
        """
        try Data(tokens.utf8).write(to: root.appendingPathComponent("claude-code-tokens.json"), options: [.atomic])

        let changed = try switcher.migrateStoredClaudeAccountsUsingIdentityCache()
        assert(changed, "Expected migration to report changed=true")

        let migrated = try store.loadSnapshot()
        let claudeAccounts = migrated.accounts.filter { $0.service == .claude }
        assert(claudeAccounts.count == 1, "Expected duplicate Claude accounts to merge into one")
        assert(claudeAccounts[0].id == canonical, "Expected canonical Claude account ID")
        assert(claudeAccounts[0].rootPath.hasSuffix("/accounts/\(canonical)"), "Expected canonical Claude root path")

        let profileIDs = Set(migrated.profiles.compactMap(\.claudeAccountId))
        assert(profileIDs == Set([canonical]), "Expected all profiles to point to canonical Claude account ID")

        let canonicalCredPath = accountsDir.appendingPathComponent(canonical, isDirectory: true)
            .appendingPathComponent(".claude/.credentials.json")
        let canonicalCreds = try Data(contentsOf: canonicalCredPath)
        assert(canonicalCreds == oldBCreds, "Expected newest account credentials to win during merge")
        assert(!fm.fileExists(atPath: oldARoot.path), "Expected old Claude account dir A removed")
        assert(!fm.fileExists(atPath: oldBRoot.path), "Expected old Claude account dir B removed")

        let migratedIdentitiesData = try Data(contentsOf: root.appendingPathComponent("usage-identities.json"))
        guard let migratedIdentities = try JSONSerialization.jsonObject(with: migratedIdentitiesData) as? [String: Any] else {
            assertionFailure("Expected usage-identities.json object")
            return
        }
        assert(migratedIdentities[canonical] != nil, "Expected canonical usage identity key")
        assert(migratedIdentities[oldA] == nil, "Expected old identity key A removed")
        assert(migratedIdentities[oldB] == nil, "Expected old identity key B removed")

        let migratedTokensData = try Data(contentsOf: root.appendingPathComponent("claude-code-tokens.json"))
        guard let migratedTokens = try JSONSerialization.jsonObject(with: migratedTokensData) as? [String: [String: Any]] else {
            assertionFailure("Expected claude-code-tokens.json object")
            return
        }
        assert(migratedTokens[canonical] != nil, "Expected canonical Claude token key")
        assert(migratedTokens[oldA] == nil, "Expected old token key A removed")
        assert(migratedTokens[oldB] == nil, "Expected old token key B removed")
    }

    private static func makeCodexCredential(
        accessToken: String,
        accountId: String,
        idToken: String?,
        refreshToken: String?
    ) throws -> Data {
        var tokens: [String: Any] = [
            "access_token": accessToken,
            "account_id": accountId,
        ]
        if let idToken {
            tokens["id_token"] = idToken
        }
        if let refreshToken {
            tokens["refresh_token"] = refreshToken
        }

        let root: [String: Any] = ["tokens": tokens]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func parseCodexTokens(from data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ProfileSwitcherTests", code: 1)
        }
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw NSError(domain: "ProfileSwitcherTests", code: 2)
        }
        return tokens
    }
}
