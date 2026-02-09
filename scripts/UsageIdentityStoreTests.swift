import Foundation

@main
enum UsageIdentityStoreTests {
    static func main() async throws {
        try await testInvalidateKeepsPlanOverride()
        try await testSnapshotDedupesSameProviderEmailAndTeam()
        try await testUpdateDoesNotCreateDuplicateIdentityForSameSignature()
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

    private static func testSnapshotDedupesSameProviderEmailAndTeam() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-island-identity-dedupe-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("usage-identities.json")
        let seed = """
        {
          "acct_claude_dup_a": {
            "claudeIsTeam": true,
            "email": "z@insightquest.io",
            "plan": null
          },
          "acct_claude_dup_b": {
            "claudeIsTeam": true,
            "email": " Z@InsightQuest.io ",
            "plan": "Max5"
          },
          "acct_claude_personal": {
            "claudeIsTeam": false,
            "email": "z@insightquest.io",
            "plan": "Max20"
          },
          "acct_codex_dup_a": {
            "email": "icedac@gmail.com",
            "plan": null
          },
          "acct_codex_dup_b": {
            "email": " icedac@gmail.com ",
            "plan": null
          }
        }
        """
        try Data(seed.utf8).write(to: fileURL, options: [.atomic])

        let store = UsageIdentityStore(rootDir: root)
        let snapshot = try await store.snapshot()

        let teamClaude = snapshot.filter { key, value in
            key.hasPrefix("acct_claude_") &&
                normalizeEmail(value.email) == "z@insightquest.io" &&
                value.claudeIsTeam == true
        }
        assert(teamClaude.count == 1, "Expected team Claude duplicates to be merged.")
        assert(teamClaude.first?.value.plan == "Max5", "Expected merged entry to preserve non-nil plan.")

        let personalClaude = snapshot.filter { key, value in
            key.hasPrefix("acct_claude_") &&
                normalizeEmail(value.email) == "z@insightquest.io" &&
                value.claudeIsTeam == false
        }
        assert(personalClaude.count == 1, "Expected personal Claude identity to stay distinct from team identity.")

        let codex = snapshot.filter { key, value in
            key.hasPrefix("acct_codex_") &&
                normalizeEmail(value.email) == "icedac@gmail.com"
        }
        assert(codex.count == 1, "Expected Codex duplicates to be merged by provider+email.")
    }

    private static func testUpdateDoesNotCreateDuplicateIdentityForSameSignature() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-island-identity-update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("usage-identities.json")
        let seed = """
        {
          "acct_claude_old": {
            "claudeIsTeam": true,
            "email": "z@insightquest.io",
            "plan": "Max5"
          }
        }
        """
        try Data(seed.utf8).write(to: fileURL, options: [.atomic])

        let store = UsageIdentityStore(rootDir: root)
        try await store.update(
            accountId: "acct_claude_new",
            email: " z@insightquest.io ",
            tier: "Max 5x",
            claudeIsTeam: true
        )

        let snapshot = try await store.snapshot()
        let matches = snapshot.filter { key, value in
            key.hasPrefix("acct_claude_") &&
                normalizeEmail(value.email) == "z@insightquest.io" &&
                value.claudeIsTeam == true
        }

        assert(matches.count == 1, "Expected update to avoid creating duplicate identities for same signature.")
        assert(matches.first?.value.plan == "Max5", "Expected plan override to survive dedup merge.")
    }

    private static func normalizeEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
