import Foundation

struct UsageIdentities: Sendable {
    let claudeEmail: String?
    let codexEmail: String?
    let geminiEmail: String?

    static let empty = UsageIdentities(
        claudeEmail: nil,
        codexEmail: nil,
        geminiEmail: nil
    )
}

struct UsageSnapshot: Sendable, Identifiable {
    let profileName: String
    let output: CheckUsageOutput?
    let identities: UsageIdentities
    let fetchedAt: Date?
    let isStale: Bool
    let errorMessage: String?

    var id: String { profileName }
}

enum UsageFetcherError: LocalizedError {
    case vendoredScriptNotFound
    case dockerFailed(exitCode: Int32, stderr: String)
    case invalidJSON(underlying: Error)
    case noCredentialsFound

    var errorDescription: String? {
        switch self {
        case .vendoredScriptNotFound:
            return "Vendored check-usage.js not found in app bundle."
        case .dockerFailed(let exitCode, let stderr):
            if stderr.isEmpty {
                return "Docker run failed (exit code \(exitCode))."
            }
            return "Docker run failed (exit code \(exitCode)): \(stderr)"
        case .invalidJSON:
            return "Failed to parse check-usage JSON output."
        case .noCredentialsFound:
            return "No CLI credentials found for Claude/Codex/Gemini. Log in and try again."
        }
    }
}

final class UsageFetcher {
    private let accountStore: AccountStore
    private let cache: UsageCache
    private let dockerImage: String
    private let identityCache = IdentityCache()

    init(
        accountStore: AccountStore = AccountStore(),
        cache: UsageCache = UsageCache(),
        dockerImage: String = "node:20-alpine"
    ) {
        self.accountStore = accountStore
        self.cache = cache
        self.dockerImage = dockerImage
    }

    func fetchSnapshot(for profile: UsageProfile) async -> UsageSnapshot {
        do {
            let snapshot = try accountStore.loadSnapshot()
            let identities = await resolveIdentitiesCached(
                key: profile.name,
                credentials: loadCredentials(profile: profile, accounts: snapshot.accounts)
            )

            if let entry = await cache.getFresh(profileName: profile.name) {
                return UsageSnapshot(
                    profileName: profile.name,
                    output: entry.output,
                    identities: identities,
                    fetchedAt: entry.fetchedAt,
                    isStale: false,
                    errorMessage: nil
                )
            }

            let output = try await fetchUsageFromDocker(profile: profile, accounts: snapshot.accounts)
            await cache.set(profileName: profile.name, output: output)
            let entry = await cache.getAny(profileName: profile.name)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output ?? output,
                identities: identities,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        } catch {
            let entry = await cache.getAny(profileName: profile.name)
            let identities = await identityCache.getFresh(key: profile.name) ?? .empty
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output,
                identities: identities,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    func fetchCurrentSnapshot(credentials: ExportCredentials) async -> UsageSnapshot {
        let cacheKey = "__current__"
        let profileName = "Current"

        let identities = await resolveIdentitiesCached(key: cacheKey, credentials: credentials)

        if let entry = await cache.getFresh(profileName: cacheKey) {
            return UsageSnapshot(
                profileName: profileName,
                output: entry.output,
                identities: identities,
                fetchedAt: entry.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        }

        do {
            let output = try await fetchUsageFromDocker(credentials: credentials)
            await cache.set(profileName: cacheKey, output: output)
            let entry = await cache.getAny(profileName: cacheKey)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output ?? output,
                identities: identities,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        } catch {
            let entry = await cache.getAny(profileName: cacheKey)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output,
                identities: identities,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Internals

    private func fetchUsageFromDocker(profile: UsageProfile, accounts: [UsageAccount]) async throws -> CheckUsageOutput {
        let tempHomeURL = try buildTempHome(profile: profile, accounts: accounts)
        defer { try? FileManager.default.removeItem(at: tempHomeURL) }
        return try await fetchUsageFromDocker(homeURL: tempHomeURL)
    }

    private func fetchUsageFromDocker(credentials: ExportCredentials) async throws -> CheckUsageOutput {
        let tempHomeURL = try buildTempHome(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: tempHomeURL) }

        return try await fetchUsageFromDocker(homeURL: tempHomeURL)
    }

    private func fetchUsageFromDocker(homeURL: URL) async throws -> CheckUsageOutput {
        let scriptURL = try Self.vendoredScriptURL()

        try stageVendoredScript(into: homeURL, scriptURL: scriptURL)

        let scriptPathInContainer = "/home/node/.claude-island-scripts/check-usage.js"

        let json: Data
        do {
            json = try await runDockerCheckUsage(
                homeURL: homeURL,
                scriptPathInContainer: scriptPathInContainer,
                dockerContext: nil
            )
        } catch let error as UsageFetcherError {
            if case .dockerFailed(_, let stderr) = error,
               stderr.contains("Cannot find module") || stderr.contains("MODULE_NOT_FOUND") {
                json = try await runDockerCheckUsage(
                    homeURL: homeURL,
                    scriptPathInContainer: scriptPathInContainer,
                    dockerContext: "desktop-linux"
                )
            } else {
                throw error
            }
        }

        do {
            return try Self.decodeUsageOutput(json)
        } catch {
            throw UsageFetcherError.invalidJSON(underlying: error)
        }
    }

    static func vendoredScriptURL(bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: "check-usage", withExtension: "js") {
            return url
        }
        throw UsageFetcherError.vendoredScriptNotFound
    }

    private func buildTempHome(profile: UsageProfile, accounts: [UsageAccount]) throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-island/tmp-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let tempHome = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        try copyServiceDir(
            service: .claude,
            accountId: profile.claudeAccountId,
            accounts: accounts,
            toHome: tempHome
        )
        try copyServiceDir(
            service: .codex,
            accountId: profile.codexAccountId,
            accounts: accounts,
            toHome: tempHome
        )
        try copyServiceDir(
            service: .gemini,
            accountId: profile.geminiAccountId,
            accounts: accounts,
            toHome: tempHome
        )

        return tempHome
    }

    private func buildTempHome(credentials: ExportCredentials) throws -> URL {
        if credentials.claude == nil, credentials.codex == nil, credentials.gemini == nil {
            throw UsageFetcherError.noCredentialsFound
        }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-island/tmp-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let tempHome = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        if let claudeData = credentials.claude {
            let dir = tempHome.appendingPathComponent(".claude", isDirectory: true)
            try writeFile(data: claudeData, to: dir.appendingPathComponent(".credentials.json"))
        }

        if let codexData = credentials.codex {
            let dir = tempHome.appendingPathComponent(".codex", isDirectory: true)
            try writeFile(data: codexData, to: dir.appendingPathComponent("auth.json"))
        }

        if let geminiData = credentials.gemini {
            let dir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
            try writeFile(data: geminiData, to: dir.appendingPathComponent("oauth_creds.json"))
        }

        return tempHome
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

    private func copyServiceDir(
        service: UsageService,
        accountId: String?,
        accounts: [UsageAccount],
        toHome homeURL: URL
    ) throws {
        guard let accountId else { return }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }

        let subdirName: String
        switch service {
        case .claude: subdirName = ".claude"
        case .codex: subdirName = ".codex"
        case .gemini: subdirName = ".gemini"
        }

        let accountRoot = URL(fileURLWithPath: account.rootPath, isDirectory: true)
        let sourceURL = accountRoot.appendingPathComponent(subdirName, isDirectory: true)
        let destinationURL = homeURL.appendingPathComponent(subdirName, isDirectory: true)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func stageVendoredScript(into homeURL: URL, scriptURL: URL) throws {
        let scriptsDir = homeURL.appendingPathComponent(".claude-island-scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let packageURL = scriptURL.deletingLastPathComponent().appendingPathComponent("package.json")

        let destinationScriptURL = scriptsDir.appendingPathComponent("check-usage.js")
        let destinationPackageURL = scriptsDir.appendingPathComponent("package.json")

        try? FileManager.default.removeItem(at: destinationScriptURL)
        try FileManager.default.copyItem(at: scriptURL, to: destinationScriptURL)

        if FileManager.default.fileExists(atPath: packageURL.path) {
            try? FileManager.default.removeItem(at: destinationPackageURL)
            try FileManager.default.copyItem(at: packageURL, to: destinationPackageURL)
        } else {
            let fallback = """
            {
              "name": "claude-dashboard-vendored",
              "private": true,
              "type": "module"
            }
            """
            try Data(fallback.utf8).write(to: destinationPackageURL, options: [.atomic])
        }
    }

    private func runDockerCheckUsage(
        homeURL: URL,
        scriptPathInContainer: String,
        dockerContext: String?
    ) async throws -> Data {

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments: [String] = ["docker"]
        if let dockerContext {
            arguments.append(contentsOf: ["--context", dockerContext])
        }
        arguments.append(contentsOf: [
            "run",
            "--rm",
            "--user", "node",
            "--env", "HOME=/home/node",
            "--volume", "\(homeURL.path):/home/node",
            dockerImage,
            "node", scriptPathInContainer, "--json",
        ])

        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    continuation.resume(
                        throwing: UsageFetcherError.dockerFailed(exitCode: proc.terminationStatus, stderr: stderr)
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func decodeUsageOutput(_ data: Data) throws -> CheckUsageOutput {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CheckUsageOutput.self, from: data)
    }
}

// MARK: - Identities

private actor IdentityCache {
    struct Entry: Sendable {
        let identities: UsageIdentities
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 3600) {
        self.ttl = ttl
    }

    func getFresh(key: String, now: Date = Date()) -> UsageIdentities? {
        guard let entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.fetchedAt) > ttl { return nil }
        return entry.identities
    }

    func set(key: String, identities: UsageIdentities, fetchedAt: Date = Date()) {
        entries[key] = Entry(identities: identities, fetchedAt: fetchedAt)
    }
}

private extension UsageFetcher {
    func resolveIdentitiesCached(key: String, credentials: ExportCredentials) async -> UsageIdentities {
        if let cached = await identityCache.getFresh(key: key) { return cached }
        let identities = await resolveIdentities(credentials: credentials)
        await identityCache.set(key: key, identities: identities)
        return identities
    }

    func loadCredentials(profile: UsageProfile, accounts: [UsageAccount]) -> ExportCredentials {
        ExportCredentials(
            claude: loadCredentialFile(
                accounts: accounts,
                accountId: profile.claudeAccountId,
                relativePath: ".claude/.credentials.json"
            ),
            codex: loadCredentialFile(
                accounts: accounts,
                accountId: profile.codexAccountId,
                relativePath: ".codex/auth.json"
            ),
            gemini: loadCredentialFile(
                accounts: accounts,
                accountId: profile.geminiAccountId,
                relativePath: ".gemini/oauth_creds.json"
            )
        )
    }

    func loadCredentialFile(accounts: [UsageAccount], accountId: String?, relativePath: String) -> Data? {
        guard let accountId else { return nil }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return nil }

        let root = URL(fileURLWithPath: account.rootPath, isDirectory: true)
        let url = root.appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }

    func resolveIdentities(credentials: ExportCredentials) async -> UsageIdentities {
        async let claudeEmailTask = resolveClaudeEmail(credentials: credentials.claude)
        let codexEmail = resolveJWTEmail(credentials: credentials.codex)
        let geminiEmail = resolveJWTEmail(credentials: credentials.gemini)
        let claudeEmail = await claudeEmailTask

        return UsageIdentities(
            claudeEmail: claudeEmail,
            codexEmail: codexEmail,
            geminiEmail: geminiEmail
        )
    }

    func resolveClaudeEmail(credentials: Data?) async -> String? {
        guard let token = extractClaudeAccessToken(credentials: credentials) else { return nil }
        return await fetchClaudeProfileEmail(accessToken: token)
    }

    func extractClaudeAccessToken(credentials: Data?) -> String? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    func fetchClaudeProfileEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-island", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let email = root["email"] as? String, email.contains("@") { return email }

            return findFirstEmailString(in: root)
        } catch {
            return nil
        }
    }

    func resolveJWTEmail(credentials: Data?) -> String? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }
        return findJWTEmail(in: root)
    }

    func findJWTEmail(in object: Any) -> String? {
        if let value = object as? String {
            return decodeJWTPayloadEmail(fromToken: value)
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findJWTEmail(in: value) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findJWTEmail(in: value) { return found }
            }
        }

        return nil
    }

    func decodeJWTPayloadEmail(fromToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let payloadBase64URL = String(parts[1])
        guard let payloadData = decodeBase64URL(payloadBase64URL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }

        if let email = root["email"] as? String, email.contains("@") { return email }
        if let email = root["preferred_username"] as? String, email.contains("@") { return email }
        return findFirstEmailString(in: root)
    }

    func findFirstEmailString(in object: Any) -> String? {
        if let value = object as? String, value.contains("@"), value.count < 200 {
            return value
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findFirstEmailString(in: value) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findFirstEmailString(in: value) { return found }
            }
        }

        return nil
    }

    func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }
}
