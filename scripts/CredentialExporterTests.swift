import Foundation

@main
enum CredentialExporterTests {
    static func main() throws {
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

        print("OK")
    }
}
