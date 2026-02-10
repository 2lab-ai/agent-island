import Foundation

struct ExportCredentials {
    let claude: Data?
    let codex: Data?
    let gemini: Data?
}

struct ExportResult {
    let claudeWritten: Bool
    let codexWritten: Bool
    let geminiWritten: Bool
}

final class CredentialExporter {
    func loadCurrentCredentials() -> ExportCredentials {
        ExportCredentials(
            claude: readClaudeCredentials(),
            codex: readCodexCredentials(),
            gemini: readGeminiCredentials()
        )
    }

    func exportCurrentCredentials(to accountRoot: URL) throws -> ExportResult {
        let credentials = loadCurrentCredentials()
        return try export(credentials, to: accountRoot)
    }

    func export(_ credentials: ExportCredentials, to accountRoot: URL) throws -> ExportResult {
        var claudeWritten = false
        var codexWritten = false
        var geminiWritten = false

        if let claudeData = credentials.claude {
            let dir = accountRoot.appendingPathComponent(".claude")
            try writeFile(data: claudeData, to: dir.appendingPathComponent(".credentials.json"))
            claudeWritten = true
        }

        if let codexData = credentials.codex {
            let dir = accountRoot.appendingPathComponent(".codex")
            try writeFile(data: codexData, to: dir.appendingPathComponent("auth.json"))
            codexWritten = true
        }

        if let geminiData = credentials.gemini {
            let dir = accountRoot.appendingPathComponent(".gemini")
            try writeFile(data: geminiData, to: dir.appendingPathComponent("oauth_creds.json"))
            geminiWritten = true
        }

        return ExportResult(
            claudeWritten: claudeWritten,
            codexWritten: codexWritten,
            geminiWritten: geminiWritten
        )
    }

    private func readClaudeCredentials() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path) {
            return data
        }
        if let keychain = readKeychain(service: "Claude Code-credentials") {
            return Data(keychain.utf8)
        }
        return nil
    }

    private func readCodexCredentials() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        return try? Data(contentsOf: path)
    }

    private func readGeminiCredentials() -> Data? {
        if let keychain = readKeychain(service: "gemini-cli-oauth", account: "main-account") {
            return Data(keychain.utf8)
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        return try? Data(contentsOf: path)
    }

    private func writeFile(data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func readKeychain(service: String, account: String? = nil) -> String? {
        var arguments = ["find-generic-password", "-s", service]
        if let accountValue = account {
            arguments.append(contentsOf: ["-a", accountValue])
        }
        arguments.append("-w")
        return runCommand(executable: "/usr/bin/security", arguments: arguments)
    }

    private func runCommand(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
