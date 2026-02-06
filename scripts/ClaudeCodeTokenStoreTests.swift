import Foundation

@main
enum ClaudeCodeTokenStoreTests {
    static func main() async throws {
        try await testEnabledFlag()
        try await testLegacyUpgrade()
        print("OK")
    }

    private static func testEnabledFlag() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agent-island-claude-code-token-store-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let store = ClaudeCodeTokenStore(rootDir: dir)
        let accountId = "acct_claude_test"

        try await store.saveToken(accountId: accountId, token: "abc")

        let status1 = try await store.statusSnapshot()
        assert(status1[accountId] == ClaudeCodeTokenStatus(isSet: true, isEnabled: true))
        let token1 = try await store.loadTokenIfEnabled(accountId: accountId)
        assert(token1 == "abc")

        try await store.setEnabled(accountId: accountId, enabled: false)

        let status2 = try await store.statusSnapshot()
        assert(status2[accountId] == ClaudeCodeTokenStatus(isSet: true, isEnabled: false))
        let token2 = try await store.loadTokenIfEnabled(accountId: accountId)
        assert(token2 == nil)
        let rawToken = try await store.loadToken(accountId: accountId)
        assert(rawToken == "abc")

        try await store.setEnabled(accountId: accountId, enabled: true)
        let token3 = try await store.loadTokenIfEnabled(accountId: accountId)
        assert(token3 == "abc")
    }

    private static func testLegacyUpgrade() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agent-island-claude-code-token-store-legacy-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("claude-code-tokens.json")
        let legacyJson = """
        {
          "acct_claude_legacy": " legacy-token "
        }
        """
        try Data(legacyJson.utf8).write(to: fileURL, options: [.atomic])

        let store = ClaudeCodeTokenStore(rootDir: dir)
        let status = try await store.statusSnapshot()
        assert(status["acct_claude_legacy"] == ClaudeCodeTokenStatus(isSet: true, isEnabled: true))

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([String: ClaudeCodeTokenStore.Entry].self, from: data)
        assert(decoded["acct_claude_legacy"] == ClaudeCodeTokenStore.Entry(token: "legacy-token", enabled: true))
    }
}
