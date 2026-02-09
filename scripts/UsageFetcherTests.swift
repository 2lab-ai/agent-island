import Foundation

@main
enum UsageFetcherTests {
    static func main() async throws {
        try testDecodeUsageOutput()
        try await testCacheTTL()
        try await testCurrentIdentityCacheInvalidatesWhenCredentialsChange()
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
}
