import Foundation

@main
enum UsageFetcherTests {
    static func main() async throws {
        try testDecodeUsageOutput()
        try await testCacheTTL()
        try await testCurrentIdentityCacheInvalidatesWhenCredentialsChange()
        try await testCurrentSnapshotForceRefreshBypassesFreshCache()
        try await testProfileTokenRefreshReflectsCredentialUpdateAfterDockerRun()
        print("OK")
    }

    private static func testDecodeUsageOutput() throws {
        let json = """
        {
          "claude": {
            "name": "Claude",
            "available": true,
            "error": false,
            "fiveHourPercent": 12,
            "sevenDayPercent": 34,
            "fiveHourReset": "2026-02-05T10:00:00.000Z",
            "sevenDayReset": "2026-02-12T10:00:00.000Z",
            "model": "claude-3-5-sonnet",
            "plan": "pro",
            "buckets": null
          },
          "codex": null,
          "gemini": null,
          "zai": null,
          "recommendation": "claude",
          "recommendationReason": "lowest usage"
        }
        """

        let output = try UsageFetcher.decodeUsageOutput(Data(json.utf8))
        assert(output.claude.available)
        assert(output.claude.fiveHourPercent == 12)
        assert(output.claude.sevenDayPercent == 34)
        assert(output.codex == nil)
        assert(output.gemini == nil)
        assert(output.zai == nil)
        assert(output.recommendation == "claude")
        assert(output.recommendationReason == "lowest usage")
    }

    private static func testCacheTTL() async throws {
        let cache = UsageCache(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 0)

        let json = """
        {
          "claude": { "name": "Claude", "available": true, "error": false },
          "codex": null,
          "gemini": null,
          "zai": null,
          "recommendation": null,
          "recommendationReason": "n/a"
        }
        """

        let output = try UsageFetcher.decodeUsageOutput(Data(json.utf8))
        await cache.set(profileName: "A", output: output, fetchedAt: t0)

        let freshAtT0 = await cache.getFresh(profileName: "A", now: t0)
        assert(freshAtT0 != nil)

        let t1 = Date(timeIntervalSince1970: 61)
        let freshAtT1 = await cache.getFresh(profileName: "A", now: t1)
        assert(freshAtT1 == nil)

        let anyAtT1 = await cache.getAny(profileName: "A")
        assert(anyAtT1 != nil)
    }

    private static func testCurrentIdentityCacheInvalidatesWhenCredentialsChange() async throws {
        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: UsageCache(ttl: 0)
        )

        let firstCredentials = ExportCredentials(
            claude: nil,
            codex: try makeJWTBackedCredential(email: "dev1@insightquest.io"),
            gemini: nil
        )

        let secondCredentials = ExportCredentials(
            claude: nil,
            codex: try makeJWTBackedCredential(email: "z@insightquest.io"),
            gemini: nil
        )

        let first = await fetcher.fetchCurrentSnapshot(credentials: firstCredentials)
        assert(first.identities.codexEmail == "dev1@insightquest.io")

        let second = await fetcher.fetchCurrentSnapshot(credentials: secondCredentials)
        assert(second.identities.codexEmail == "z@insightquest.io")
    }

    private static func testCurrentSnapshotForceRefreshBypassesFreshCache() async throws {
        let cache = UsageCache(ttl: 600)
        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: cache
        )

        let json = """
        {
          "claude": { "name": "Claude", "available": true, "error": false },
          "codex": null,
          "gemini": null,
          "zai": null,
          "recommendation": null,
          "recommendationReason": "n/a"
        }
        """
        let output = try UsageFetcher.decodeUsageOutput(Data(json.utf8))
        await cache.set(profileName: "__current__", output: output)

        let empty = ExportCredentials(claude: nil, codex: nil, gemini: nil)
        let cached = await fetcher.fetchCurrentSnapshot(credentials: empty)
        assert(cached.isStale == false, "Expected fresh cache path when force refresh is not requested.")

        let forced = await fetcher.fetchCurrentSnapshot(credentials: empty, forceRefresh: true)
        assert(forced.isStale == true, "Expected forced refresh to bypass cache and fail into stale fallback with empty credentials.")
    }

    private static func testProfileTokenRefreshReflectsCredentialUpdateAfterDockerRun() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("usage-fetcher-refresh-\(UUID().uuidString)", isDirectory: true)
        let accountRoot = root.appendingPathComponent("accounts/acct_claude_test", isDirectory: true)
        let credentialsURL = accountRoot.appendingPathComponent(".claude/.credentials.json")
        try fm.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let issuedAt = Date(timeIntervalSince1970: 1_910_000_000)
        let oldExpiry = Date(timeIntervalSince1970: 1_910_003_600)
        let newExpiry = Date(timeIntervalSince1970: 1_910_010_800)
        let initialClaude = try makeClaudeCredential(expiresAt: oldExpiry, issuedAt: issuedAt)
        try initialClaude.write(to: credentialsURL, options: [.atomic])

        let accountStore = AccountStore(rootDir: root)
        try accountStore.saveSnapshot(
            AccountsSnapshot(
                accounts: [
                    UsageAccount(
                        id: "acct_claude_test",
                        service: .claude,
                        label: "claude:test",
                        rootPath: accountRoot.path,
                        updatedAt: Date()
                    ),
                ],
                profiles: []
            )
        )

        let fetcher = UsageFetcher(
            accountStore: accountStore,
            cache: UsageCache(ttl: 0),
            dockerRunner: { homeURL, _, _ in
                let updatedURL = homeURL.appendingPathComponent(".claude/.credentials.json")
                let updatedData = try makeClaudeCredential(expiresAt: newExpiry, issuedAt: issuedAt)
                try updatedData.write(to: updatedURL, options: [.atomic])
                try updatedData.write(to: credentialsURL, options: [.atomic])

                let json = """
                {
                  "claude": { "name": "Claude", "available": true, "error": false },
                  "codex": null,
                  "gemini": null,
                  "zai": null,
                  "recommendation": null,
                  "recommendationReason": "n/a"
                }
                """
                return Data(json.utf8)
            }
        )

        let profile = UsageProfile(
            name: "refresh-test",
            claudeAccountId: "acct_claude_test",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        let snapshot = await fetcher.fetchSnapshot(for: profile, forceRefresh: true)

        guard let expiresAt = snapshot.tokenRefresh.claude?.expiresAt else {
            assertionFailure("Expected Claude token refresh info")
            return
        }

        let latestOnDisk = try readClaudeExpiresAt(from: Data(contentsOf: credentialsURL))
        assert(
            abs(expiresAt.timeIntervalSince(newExpiry)) < 1,
            "Expected snapshot to use refreshed credential expiration. snapshot=\(expiresAt.timeIntervalSince1970) disk=\(latestOnDisk.timeIntervalSince1970) expected=\(newExpiry.timeIntervalSince1970)"
        )
    }

    private static func makeJWTBackedCredential(email: String) throws -> Data {
        let header = try base64URLJSON(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URLJSON(["email": email, "exp": 1_910_000_000]) // 2030-07-18 UTC
        let token = "\(header).\(payload).signature"

        let root: [String: Any] = [
            "tokens": [
                "access_token": token,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func makeClaudeCredential(expiresAt: Date, issuedAt: Date) throws -> Data {
        let root: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "at-old",
                "refreshToken": "rt-stable",
                "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
                "issuedAt": Int(issuedAt.timeIntervalSince1970 * 1000),
                "rateLimitTier": "default_claude_max_20x",
                "subscriptionType": "max",
                "scopes": ["user:profile"],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func readClaudeExpiresAt(from data: Data) throws -> Date {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UsageFetcherTests", code: 1)
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw NSError(domain: "UsageFetcherTests", code: 2)
        }
        guard let millis = oauth["expiresAt"] as? NSNumber else {
            throw NSError(domain: "UsageFetcherTests", code: 3)
        }
        return Date(timeIntervalSince1970: millis.doubleValue / 1000)
    }

    private static func base64URLJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
