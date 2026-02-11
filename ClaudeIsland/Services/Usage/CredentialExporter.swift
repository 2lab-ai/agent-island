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
        let fileData = try? Data(contentsOf: path)
        guard let keychain = readKeychain(service: "Claude Code-credentials"),
              let keychainData = keychain.data(using: .utf8)
        else {
            return fileData
        }

        return mergedClaudeCredentials(
            keychainData: keychainData,
            fallbackFileData: fileData
        ) ?? keychainData
    }

    private func mergedClaudeCredentials(keychainData: Data, fallbackFileData: Data?) -> Data? {
        guard var keychainRoot = parseJSONObject(from: keychainData) else { return nil }

        let keychainRefreshToken = readClaudeRefreshToken(from: keychainRoot)
        let fallbackRoot: [String: Any]? = {
            if let fallbackFileData,
               let parsed = parseJSONObject(from: fallbackFileData),
               let keychainRefreshToken,
               readClaudeRefreshToken(from: parsed) == keychainRefreshToken {
                return parsed
            }

            if let keychainRefreshToken,
               let matched = loadStoredClaudeRoot(refreshToken: keychainRefreshToken) {
                return matched
            }

            return fallbackFileData.flatMap(parseJSONObject)
        }()

        guard let fallbackRoot else {
            return keychainData
        }

        keychainRoot = mergeClaudeMetadata(primary: keychainRoot, fallback: fallbackRoot)
        return try? JSONSerialization.data(withJSONObject: keychainRoot, options: [.prettyPrinted])
    }

    private func mergeClaudeMetadata(primary: [String: Any], fallback: [String: Any]) -> [String: Any] {
        var merged = primary
        var primaryOAuth = primary["claudeAiOauth"] as? [String: Any] ?? [:]
        let fallbackOAuth = fallback["claudeAiOauth"] as? [String: Any] ?? [:]

        copyIfMissing(key: "email", from: fallback, to: &merged)
        copyIfMissing(key: "account", from: fallback, to: &merged)
        copyIfMissing(key: "organization", from: fallback, to: &merged)
        copyIfMissing(key: "subscriptionType", from: fallback, to: &merged)
        copyIfMissing(key: "rateLimitTier", from: fallback, to: &merged)
        copyIfMissing(key: "isTeam", from: fallback, to: &merged)

        copyIfMissing(key: "email", from: fallbackOAuth, to: &primaryOAuth)
        copyIfMissing(key: "account", from: fallbackOAuth, to: &primaryOAuth)
        copyIfMissing(key: "organization", from: fallbackOAuth, to: &primaryOAuth)
        copyIfMissing(key: "subscriptionType", from: fallbackOAuth, to: &primaryOAuth)
        copyIfMissing(key: "rateLimitTier", from: fallbackOAuth, to: &primaryOAuth)
        copyIfMissing(key: "isTeam", from: fallbackOAuth, to: &primaryOAuth)

        merged["claudeAiOauth"] = primaryOAuth
        return merged
    }

    private func copyIfMissing(key: String, from source: [String: Any], to destination: inout [String: Any]) {
        if destination[key] != nil {
            return
        }
        if let value = source[key] {
            destination[key] = value
        }
    }

    private func loadStoredClaudeRoot(refreshToken: String) -> [String: Any]? {
        let accountsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-island/accounts", isDirectory: true)
        guard let accountDirectories = try? FileManager.default.contentsOfDirectory(
            at: accountsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for accountDirectory in accountDirectories {
            let credentialURL = accountDirectory.appendingPathComponent(".claude/.credentials.json")
            guard let data = try? Data(contentsOf: credentialURL),
                  let root = parseJSONObject(from: data)
            else {
                continue
            }
            if readClaudeRefreshToken(from: root) == refreshToken {
                return root
            }
        }
        return nil
    }

    private func parseJSONObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readClaudeRefreshToken(from root: [String: Any]) -> String? {
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        guard let raw = oauth["refreshToken"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
