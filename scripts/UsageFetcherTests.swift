import Foundation

@main
enum UsageFetcherTests {
    static func main() async throws {
        try testDecodeUsageOutput()
        try await testCacheTTL()
        try testIncompleteIdentityCacheEntryIsNotReused()
        try await testCurrentIdentityCacheInvalidatesWhenCredentialsChange()
        try await testCurrentSnapshotForceRefreshBypassesFreshCache()
        try await testClaudeSubscriptionMetadataFallbackFromCredentials()
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

    private static func testIncompleteIdentityCacheEntryIsNotReused() throws {
        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: UsageCache(ttl: 0)
        )

        let claudeCredentials = ExportCredentials(
            claude: Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\"}}".utf8),
            codex: nil,
            gemini: nil
        )
        let missingClaudeIdentity = UsageIdentities(
            claudeEmail: nil,
            claudeTier: nil,
            claudeIsTeam: nil,
            codexEmail: nil,
            geminiEmail: nil
        )
        assert(fetcher.shouldReuseCachedIdentities(missingClaudeIdentity, credentials: claudeCredentials) == false)

        let completeClaudeIdentity = UsageIdentities(
            claudeEmail: "ai@insightquest.io",
            claudeTier: nil,
            claudeIsTeam: nil,
            codexEmail: nil,
            geminiEmail: nil
        )
        assert(fetcher.shouldReuseCachedIdentities(completeClaudeIdentity, credentials: claudeCredentials) == true)

        let codexCredentials = ExportCredentials(
            claude: nil,
            codex: Data("{\"tokens\":{\"access_token\":\"tok\",\"account_id\":\"acct\"}}".utf8),
            gemini: nil
        )
        let missingCodexIdentity = UsageIdentities(
            claudeEmail: nil,
            claudeTier: nil,
            claudeIsTeam: nil,
            codexEmail: nil,
            geminiEmail: nil
        )
        assert(fetcher.shouldReuseCachedIdentities(missingCodexIdentity, credentials: codexCredentials) == false)
    }

    private static func testCurrentIdentityCacheInvalidatesWhenCredentialsChange() async throws {
        let testHome = try makeIsolatedHome(name: "identity-cache")
        defer { try? FileManager.default.removeItem(at: testHome) }

        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: UsageCache(ttl: 0),
            homeDirectory: testHome
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
        let testHome = try makeIsolatedHome(name: "force-refresh")
        defer { try? FileManager.default.removeItem(at: testHome) }

        let cache = UsageCache(ttl: 600)
        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: cache,
            homeDirectory: testHome
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

    private static func testClaudeSubscriptionMetadataFallbackFromCredentials() async throws {
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

        let max20Creds = Data("""
        {
          "claudeAiOauth": {
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """.utf8)

        let max20Snapshot = await fetcher.fetchCurrentSnapshot(
            credentials: ExportCredentials(claude: max20Creds, codex: nil, gemini: nil)
        )
        assert(max20Snapshot.identities.claudeTier == "Max 20x", "Expected Max 20x tier from local credentials metadata.")
        assert(max20Snapshot.identities.claudeIsTeam == false, "Expected non-team for subscriptionType=max.")

        let team5Creds = Data("""
        {
          "claudeAiOauth": {
            "subscriptionType": "team",
            "rateLimitTier": "default_claude_max_5x"
          }
        }
        """.utf8)

        let team5Snapshot = await fetcher.fetchCurrentSnapshot(
            credentials: ExportCredentials(claude: team5Creds, codex: nil, gemini: nil)
        )
        assert(team5Snapshot.identities.claudeTier == "Max 5x", "Expected Max 5x tier from local credentials metadata.")
        assert(team5Snapshot.identities.claudeIsTeam == true, "Expected team account for subscriptionType=team.")
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

    private static func base64URLJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeIsolatedHome(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-fetcher-home-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
