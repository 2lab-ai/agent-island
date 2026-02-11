import Foundation

@main
enum UsageFetcherTests {
    static func main() async throws {
        try testDecodeUsageOutput()
        try await testCacheTTL()
        try testIncompleteIdentityCacheEntryIsNotReused()
        try await testCurrentIdentityCacheInvalidatesWhenCredentialsChange()
        try await testCurrentSnapshotForceRefreshBypassesFreshCache()
        try await testDockerSocketErrorProducesActionableIssue()
        try await testDockerCredentialHelperErrorProducesActionableIssue()
        try await testClaudeSubscriptionMetadataFallbackFromCredentials()
        try await testProfileTokenRefreshReflectsCredentialUpdateAfterDockerRun()
        try await testProfileRefreshPersistsRotatedTokenWhenExpiryEqual()
        try await testProfileRefreshSkipsOlderClaudeCredentialOnSuccessSync()
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

    private static func testDockerSocketErrorProducesActionableIssue() async throws {
        let testHome = try makeIsolatedHome(name: "docker-sock-missing")
        defer { try? FileManager.default.removeItem(at: testHome) }

        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: UsageCache(ttl: 0),
            dockerRunner: { _, _, _ in
                throw UsageFetcherError.dockerFailed(
                    exitCode: 1,
                    stderr: "failed to connect to the docker API at unix:///var/run/docker.sock: check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory"
                )
            },
            homeDirectory: testHome
        )

        let credentials = ExportCredentials(
            claude: nil,
            codex: Data("{\"tokens\":{\"access_token\":\"tok\"}}".utf8),
            gemini: nil
        )
        let snapshot = await fetcher.fetchCurrentSnapshot(credentials: credentials, forceRefresh: true)

        assert(snapshot.issue?.kind == .dockerDaemonUnavailable)
        assert(snapshot.errorMessage?.contains("Docker Desktop is not running") == true)
    }

    private static func testDockerCredentialHelperErrorProducesActionableIssue() async throws {
        let testHome = try makeIsolatedHome(name: "docker-creds-helper")
        defer { try? FileManager.default.removeItem(at: testHome) }

        let fetcher = UsageFetcher(
            accountStore: AccountStore(rootDir: FileManager.default.temporaryDirectory),
            cache: UsageCache(ttl: 0),
            dockerRunner: { _, _, _ in
                throw UsageFetcherError.dockerFailed(
                    exitCode: 127,
                    stderr: "Unable to find image 'node:20-alpine' locally docker: error getting credentials - err: exec: \"docker-credential-desktop\": executable file not found in $PATH"
                )
            },
            homeDirectory: testHome
        )

        let credentials = ExportCredentials(
            claude: nil,
            codex: Data("{\"tokens\":{\"access_token\":\"tok\"}}".utf8),
            gemini: nil
        )
        let snapshot = await fetcher.fetchCurrentSnapshot(credentials: credentials, forceRefresh: true)

        assert(snapshot.issue?.kind == .dockerCredentialHelperMissing)
        assert(snapshot.errorMessage?.contains("credential helper") == true)
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
            },
            homeDirectory: root
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

    private static func testProfileRefreshPersistsRotatedTokenWhenExpiryEqual() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("usage-fetcher-token-rotation-\(UUID().uuidString)", isDirectory: true)
        let accountRoot = root.appendingPathComponent("accounts/acct_claude_test", isDirectory: true)
        let credentialsURL = accountRoot.appendingPathComponent(".claude/.credentials.json")
        try fm.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let issuedAt = Date(timeIntervalSince1970: 1_910_000_000)
        let sharedExpiry = Date(timeIntervalSince1970: 1_910_010_800)
        let initialClaude = try makeClaudeCredential(
            accessToken: "at-before",
            refreshToken: "rt-before",
            expiresAt: sharedExpiry,
            issuedAt: issuedAt
        )
        let rotatedClaude = try makeClaudeCredential(
            accessToken: "at-after",
            refreshToken: "rt-after",
            expiresAt: sharedExpiry,
            issuedAt: issuedAt
        )
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
                try rotatedClaude.write(to: updatedURL, options: [.atomic])

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
            },
            homeDirectory: root
        )

        let profile = UsageProfile(
            name: "rotation-test",
            claudeAccountId: "acct_claude_test",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        _ = await fetcher.fetchSnapshot(for: profile, forceRefresh: true)

        let latestOnDiskData = try Data(contentsOf: credentialsURL)
        let latestOnDiskTokens = try readClaudeTokens(from: latestOnDiskData)
        assert(latestOnDiskTokens.accessToken == "at-after")
        assert(latestOnDiskTokens.refreshToken == "rt-after")
    }

    private static func testProfileRefreshSkipsOlderClaudeCredentialOnSuccessSync() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("usage-fetcher-stale-guard-\(UUID().uuidString)", isDirectory: true)
        let accountRoot = root.appendingPathComponent("accounts/acct_claude_test", isDirectory: true)
        let credentialsURL = accountRoot.appendingPathComponent(".claude/.credentials.json")
        try fm.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let issuedAt = Date(timeIntervalSince1970: 1_910_000_000)
        let latestExpiry = Date(timeIntervalSince1970: 1_910_010_800)
        let staleExpiry = Date(timeIntervalSince1970: 1_910_003_600)
        let latestCredential = try makeClaudeCredential(
            accessToken: "at-latest",
            refreshToken: "rt-latest",
            expiresAt: latestExpiry,
            issuedAt: issuedAt
        )
        let staleCredential = try makeClaudeCredential(
            accessToken: "at-stale",
            refreshToken: "rt-stale",
            expiresAt: staleExpiry,
            issuedAt: issuedAt
        )
        try latestCredential.write(to: credentialsURL, options: [.atomic])

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
                try staleCredential.write(to: updatedURL, options: [.atomic])

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
            },
            homeDirectory: root
        )

        let profile = UsageProfile(
            name: "refresh-test",
            claudeAccountId: "acct_claude_test",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        let snapshot = await fetcher.fetchSnapshot(for: profile, forceRefresh: true)

        guard let snapshotExpiry = snapshot.tokenRefresh.claude?.expiresAt else {
            assertionFailure("Expected Claude token refresh info")
            return
        }

        let latestOnDiskData = try Data(contentsOf: credentialsURL)
        let latestOnDiskExpiry = try readClaudeExpiresAt(from: latestOnDiskData)
        let latestOnDiskTokens = try readClaudeTokens(from: latestOnDiskData)

        assert(
            abs(snapshotExpiry.timeIntervalSince(latestExpiry)) < 1,
            "Expected snapshot to keep latest destination credential expiry. snapshot=\(snapshotExpiry.timeIntervalSince1970) expected=\(latestExpiry.timeIntervalSince1970)"
        )
        assert(
            abs(latestOnDiskExpiry.timeIntervalSince(latestExpiry)) < 1,
            "Expected destination credential to keep newer expiry. disk=\(latestOnDiskExpiry.timeIntervalSince1970) expected=\(latestExpiry.timeIntervalSince1970)"
        )
        assert(latestOnDiskTokens.accessToken == "at-latest")
        assert(latestOnDiskTokens.refreshToken == "rt-latest")
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

    private static func makeClaudeCredential(
        accessToken: String = "at-old",
        refreshToken: String = "rt-stable",
        expiresAt: Date,
        issuedAt: Date
    ) throws -> Data {
        let root: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
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

    private static func readClaudeTokens(from data: Data) throws -> (accessToken: String?, refreshToken: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UsageFetcherTests", code: 11)
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw NSError(domain: "UsageFetcherTests", code: 12)
        }
        return (
            accessToken: oauth["accessToken"] as? String,
            refreshToken: oauth["refreshToken"] as? String
        )
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
