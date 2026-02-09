import Foundation

@main
enum UsageIdentityStoreTests {
    static func main() async throws {
        try await testInvalidateKeepsPlanOverride()
        print("OK")
    }

    private static func testInvalidateKeepsPlanOverride() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-island-identity-store-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("usage-identities.json")
        let seed = """
        {
          "acct_claude_test": {
            "claudeIsTeam": true,
            "email": "dev1@insightquest.io",
            "plan": "max20",
            "tier": "Max 20x"
          }
        }
        """
        try Data(seed.utf8).write(to: fileURL, options: [.atomic])

        let store = UsageIdentityStore(rootDir: root)
        try await store.invalidateCachedIdentity(accountId: "acct_claude_test")

        let snapshot = try await store.snapshot()
        guard let identity = snapshot["acct_claude_test"] else {
            assertionFailure("Expected account entry after invalidation")
            return
        }

        assert(identity.email == nil)
        assert(identity.tier == nil)
        assert(identity.claudeIsTeam == nil)
        assert(identity.plan == "max20")
    }
}
