import Foundation

@main
enum CredentialExporterTests {
    static func main() throws {
        try testExportWritesAllServiceCredentials()
        try testResolveCurrentClaudeCredentialPrefersUsableFile()
        try testResolveCurrentClaudeCredentialFallsBackToUsableKeychain()
        print("OK")
    }

    private static func testExportWritesAllServiceCredentials() throws {
        let root = URL(fileURLWithPath: "/tmp/claude-island-cred-test")
        try? FileManager.default.removeItem(at: root)

        let claudeJson = #"{ "claudeAiOauth": { "accessToken": "c-token" } }"#
        let codexJson = #"{ "tokens": { "access_token": "cx-token", "account_id": "acct" } }"#
        let geminiJson = #"{ "access_token": "g-token" }"#

        let credentials = ExportCredentials(
            claude: Data(claudeJson.utf8),
            codex: Data(codexJson.utf8),
            gemini: Data(geminiJson.utf8)
        )

        let exporter = CredentialExporter()
        let result = try exporter.export(credentials, to: root)

        assert(result.claudeWritten)
        assert(result.codexWritten)
        assert(result.geminiWritten)

        let claudePath = root.appendingPathComponent(".claude/.credentials.json")
        let codexPath = root.appendingPathComponent(".codex/auth.json")
        let geminiPath = root.appendingPathComponent(".gemini/oauth_creds.json")

        let claudeData = try Data(contentsOf: claudePath)
        let codexData = try Data(contentsOf: codexPath)
        let geminiData = try Data(contentsOf: geminiPath)

        assert(String(data: claudeData, encoding: .utf8) == claudeJson)
        assert(String(data: codexData, encoding: .utf8) == codexJson)
        assert(String(data: geminiData, encoding: .utf8) == geminiJson)
    }

    private static func testResolveCurrentClaudeCredentialPrefersUsableFile() throws {
        let exporter = CredentialExporter()
        let accountsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-exporter-prefers-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: accountsRoot) }

        let fileData = try makeClaudeCredentialData(
            accessToken: "at-file",
            refreshToken: "rt-file",
            expiresAt: 1_770_827_242_571
        )
        let keychainData = try makeClaudeCredentialData(
            accessToken: "at-keychain",
            refreshToken: "rt-keychain",
            expiresAt: 1_770_823_551_952
        )

        let resolved = exporter.resolveCurrentClaudeCredentialData(
            fileData: fileData,
            keychainData: keychainData,
            accountsRoot: accountsRoot
        )
        guard let resolved else {
            assertionFailure("Expected resolved credential data")
            return
        }

        let tokens = try readClaudeTokens(from: resolved)
        assert(tokens.accessToken == "at-file")
        assert(tokens.refreshToken == "rt-file")
    }

    private static func testResolveCurrentClaudeCredentialFallsBackToUsableKeychain() throws {
        let exporter = CredentialExporter()
        let accountsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-exporter-fallback-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: accountsRoot) }

        let unusableFileData = Data(#"{ "claudeAiOauth": {} }"#.utf8)
        let keychainData = try makeClaudeCredentialData(
            accessToken: "at-keychain",
            refreshToken: "rt-keychain",
            expiresAt: 1_770_823_551_952
        )

        let resolved = exporter.resolveCurrentClaudeCredentialData(
            fileData: unusableFileData,
            keychainData: keychainData,
            accountsRoot: accountsRoot
        )
        guard let resolved else {
            assertionFailure("Expected resolved credential data")
            return
        }

        let tokens = try readClaudeTokens(from: resolved)
        assert(tokens.accessToken == "at-keychain")
        assert(tokens.refreshToken == "rt-keychain")
    }

    private static func makeClaudeCredentialData(
        accessToken: String,
        refreshToken: String,
        expiresAt: Int
    ) throws -> Data {
        let root: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": expiresAt,
                "scopes": ["user:profile"],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func readClaudeTokens(from data: Data) throws -> (accessToken: String?, refreshToken: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CredentialExporterTests", code: 1)
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw NSError(domain: "CredentialExporterTests", code: 2)
        }
        return (
            accessToken: oauth["accessToken"] as? String,
            refreshToken: oauth["refreshToken"] as? String
        )
    }
}
