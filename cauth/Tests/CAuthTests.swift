import Foundation
import XCTest

@testable import cauth

final class CAuthTests: XCTestCase {
    func testSaveCreatesEmailBasedAccountAndProfileMapping() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let activeCredPath = home.appendingPathComponent(".claude/.credentials.json")
        try writeCredentials(
            to: activeCredPath,
            accessToken: "at-original",
            refreshToken: "rt-original",
            expiresAtMillis: 1_800_000_000_000,
            email: "z@iq.io",
            isTeam: true
        )

        let keychain = ProcessRecorder()
        let app = CAuthApp(
            fileManager: .default,
            homeDir: home,
            processRunner: keychain.run
        )

        try app.saveCurrentProfile(named: "home")

        let accountID = "acct_claude_team_z_iq_io"
        let storedPath = home
            .appendingPathComponent(".agent-island/accounts/\(accountID)/.claude/.credentials.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedPath.path))

        let snapshot = try readAccountsSnapshot(home: home)
        let profileList = snapshot["profiles"] as? [[String: Any]] ?? []
        let profile = profileList.first { ($0["name"] as? String) == "home" }
        XCTAssertEqual(profile?["claudeAccountId"] as? String, accountID)
    }

    func testSwitchWritesActiveCredentialAndKeychain() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let accountID = "acct_claude_home_example_com"
        let accountRoot = home.appendingPathComponent(".agent-island/accounts/\(accountID)")
        let storedCredPath = accountRoot.appendingPathComponent(".claude/.credentials.json")
        try writeCredentials(
            to: storedCredPath,
            accessToken: "at-switched",
            refreshToken: "rt-switched",
            expiresAtMillis: 1_800_000_000_000,
            email: "home@example.com"
        )

        try writeSnapshot(
            home: home,
            accounts: [[
                "id": accountID,
                "service": "claude",
                "label": "claude:test",
                "rootPath": accountRoot.path,
                "updatedAt": "2026-02-11T00:00:00Z",
            ]],
            profiles: [[
                "name": "home",
                "claudeAccountId": accountID,
                "codexAccountId": NSNull(),
                "geminiAccountId": NSNull(),
            ]]
        )

        let keychain = ProcessRecorder()
        let app = CAuthApp(
            fileManager: .default,
            homeDir: home,
            processRunner: keychain.run
        )

        try app.switchProfile(named: "home")

        let activePath = home.appendingPathComponent(".claude/.credentials.json")
        let active = try readTokens(from: activePath)
        XCTAssertEqual(active.accessToken, "at-switched")
        XCTAssertEqual(active.refreshToken, "rt-switched")
        XCTAssertEqual(keychain.addCount, 1)
        XCTAssertTrue((keychain.lastAddedSecret ?? "").contains("at-switched"))
    }

    func testRefreshUpdatesStoredAndActiveAndKeychain() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let accountID = "acct_claude_home_example_com"
        let accountRoot = home.appendingPathComponent(".agent-island/accounts/\(accountID)")
        let accountCredPath = accountRoot.appendingPathComponent(".claude/.credentials.json")
        let activeCredPath = home.appendingPathComponent(".claude/.credentials.json")

        try writeCredentials(
            to: accountCredPath,
            accessToken: "at-before",
            refreshToken: "rt-before",
            expiresAtMillis: 1_700_000_000_000,
            email: "home@example.com"
        )
        try writeCredentials(
            to: activeCredPath,
            accessToken: "at-before",
            refreshToken: "rt-before",
            expiresAtMillis: 1_700_000_000_000,
            email: "home@example.com"
        )

        try writeSnapshot(
            home: home,
            accounts: [[
                "id": accountID,
                "service": "claude",
                "label": "claude:test",
                "rootPath": accountRoot.path,
                "updatedAt": "2026-02-11T00:00:00Z",
            ]],
            profiles: [[
                "name": "home",
                "claudeAccountId": accountID,
                "codexAccountId": NSNull(),
                "geminiAccountId": NSNull(),
            ]]
        )

        let keychain = ProcessRecorder()
        let counter = RefreshCounter()
        let app = CAuthApp(
            fileManager: .default,
            homeDir: home,
            processRunner: keychain.run,
            tokenRefreshClient: { refreshToken, _ in
                await counter.increment()
                XCTAssertEqual(refreshToken, "rt-before")
                return ClaudeRefreshPayload(
                    accessToken: "at-after",
                    refreshToken: "rt-after",
                    expiresIn: 28_800,
                    scope: "user:profile user:inference"
                )
            },
            usageClient: { _ in
                UsageSummary(
                    fiveHourPercent: 91,
                    fiveHourReset: Date(timeIntervalSinceNow: 3_600),
                    sevenDayPercent: 65,
                    sevenDayReset: Date(timeIntervalSinceNow: 7_200)
                )
            }
        )

        try await app.refreshAllProfiles()

        let refreshedStored = try readTokens(from: accountCredPath)
        let refreshedActive = try readTokens(from: activeCredPath)
        XCTAssertEqual(refreshedStored.accessToken, "at-after")
        XCTAssertEqual(refreshedStored.refreshToken, "rt-after")
        XCTAssertEqual(refreshedActive.accessToken, "at-after")
        XCTAssertEqual(refreshedActive.refreshToken, "rt-after")
        let refreshCount = await counter.value()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(keychain.addCount, 1)
        XCTAssertTrue((keychain.lastAddedSecret ?? "").contains("at-after"))
    }

    func testRefreshDedupesByRefreshTokenAcrossLegacyDuplicateAccounts() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let accountA = "acct_claude_legacy_a"
        let accountB = "acct_claude_legacy_b"
        let rootA = home.appendingPathComponent(".agent-island/accounts/\(accountA)")
        let rootB = home.appendingPathComponent(".agent-island/accounts/\(accountB)")
        let credA = rootA.appendingPathComponent(".claude/.credentials.json")
        let credB = rootB.appendingPathComponent(".claude/.credentials.json")

        try writeCredentials(
            to: credA,
            accessToken: "at-a",
            refreshToken: "rt-shared",
            expiresAtMillis: 1_700_000_000_000
        )
        try writeCredentials(
            to: credB,
            accessToken: "at-b",
            refreshToken: "rt-shared",
            expiresAtMillis: 1_700_000_000_000
        )

        try writeSnapshot(
            home: home,
            accounts: [
                [
                    "id": accountA,
                    "service": "claude",
                    "label": "claude:a",
                    "rootPath": rootA.path,
                    "updatedAt": "2026-02-11T00:00:00Z",
                ],
                [
                    "id": accountB,
                    "service": "claude",
                    "label": "claude:b",
                    "rootPath": rootB.path,
                    "updatedAt": "2026-02-11T00:00:00Z",
                ],
            ],
            profiles: [
                [
                    "name": "home",
                    "claudeAccountId": accountA,
                    "codexAccountId": NSNull(),
                    "geminiAccountId": NSNull(),
                ],
                [
                    "name": "work1",
                    "claudeAccountId": accountB,
                    "codexAccountId": NSNull(),
                    "geminiAccountId": NSNull(),
                ],
            ]
        )

        let keychain = ProcessRecorder()
        let counter = RefreshCounter()
        let app = CAuthApp(
            fileManager: .default,
            homeDir: home,
            processRunner: keychain.run,
            tokenRefreshClient: { _, _ in
                await counter.increment()
                return ClaudeRefreshPayload(
                    accessToken: "at-deduped",
                    refreshToken: "rt-deduped",
                    expiresIn: 28_800,
                    scope: "user:profile"
                )
            },
            usageClient: { _ in nil }
        )

        try await app.refreshAllProfiles()

        let a = try readTokens(from: credA)
        let b = try readTokens(from: credB)
        let refreshCount = await counter.value()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(a.accessToken, "at-deduped")
        XCTAssertEqual(b.accessToken, "at-deduped")
        XCTAssertEqual(a.refreshToken, "rt-deduped")
        XCTAssertEqual(b.refreshToken, "rt-deduped")
    }

    private func makeTempHome() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cauth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCredentials(
        to url: URL,
        accessToken: String,
        refreshToken: String,
        expiresAtMillis: Int,
        email: String? = nil,
        isTeam: Bool? = nil
    ) throws {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAtMillis,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x",
            "scopes": [
                "user:profile",
                "user:inference",
            ],
        ]
        if let email {
            oauth["email"] = email
        }
        if let isTeam {
            oauth["isTeam"] = isTeam
        }
        let root: [String: Any] = ["claudeAiOauth": oauth]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func writeSnapshot(home: URL, accounts: [[String: Any]], profiles: [[String: Any]]) throws {
        let snapshot: [String: Any] = [
            "accounts": accounts,
            "profiles": profiles,
        ]
        let root = home.appendingPathComponent(".agent-island")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("accounts.json"), options: [.atomic])
    }

    private func readAccountsSnapshot(home: URL) throws -> [String: Any] {
        let path = home.appendingPathComponent(".agent-island/accounts.json")
        let data = try Data(contentsOf: path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return root
    }

    private func readTokens(from url: URL) throws -> (accessToken: String?, refreshToken: String?) {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            oauth["accessToken"] as? String,
            oauth["refreshToken"] as? String
        )
    }
}

private final class ProcessRecorder {
    var addCount = 0
    var lastAddedSecret: String?

    func run(executable: String, arguments: [String]) -> ProcessExecutionResult {
        guard executable.hasSuffix("security") else {
            return ProcessExecutionResult(status: 1, stdout: "", stderr: "unexpected executable")
        }
        guard let command = arguments.first else {
            return ProcessExecutionResult(status: 1, stdout: "", stderr: "missing command")
        }
        if command == "find-generic-password", arguments.contains("-g") {
            return ProcessExecutionResult(
                status: 0,
                stdout: "",
                stderr: "keychain: \"acct\"<blob>=\"tester\"\n"
            )
        }
        if command == "find-generic-password", arguments.contains("-w") {
            return ProcessExecutionResult(status: 1, stdout: "", stderr: "not found")
        }
        if command == "add-generic-password" {
            addCount += 1
            if let index = arguments.firstIndex(of: "-w"), index + 1 < arguments.count {
                lastAddedSecret = arguments[index + 1]
            }
            return ProcessExecutionResult(status: 0, stdout: "", stderr: "")
        }
        return ProcessExecutionResult(status: 0, stdout: "", stderr: "")
    }
}

private actor RefreshCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
