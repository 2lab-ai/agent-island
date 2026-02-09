import Foundation

@main
enum ProfileSwitcherTests {
    static func main() throws {
        try testStableFingerprintForClaudeRefreshToken()
        try testStableFingerprintForCodexAccountID()

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
        let codexCreds = Data("{\"tokens\":{\"access_token\":\"tok\",\"account_id\":\"acct\"}}".utf8)
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
}
