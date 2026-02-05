import Foundation

struct UsageSnapshot: Sendable, Identifiable {
    let profileName: String
    let output: CheckUsageOutput?
    let fetchedAt: Date?
    let isStale: Bool
    let errorMessage: String?

    var id: String { profileName }
}

enum UsageFetcherError: LocalizedError {
    case vendoredScriptNotFound
    case dockerFailed(exitCode: Int32, stderr: String)
    case invalidJSON(underlying: Error)

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
        }
    }
}

final class UsageFetcher {
    private let accountStore: AccountStore
    private let cache: UsageCache
    private let dockerImage: String

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
        if let entry = await cache.getFresh(profileName: profile.name) {
            return UsageSnapshot(
                profileName: profile.name,
                output: entry.output,
                fetchedAt: entry.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        }

        do {
            let snapshot = try accountStore.loadSnapshot()
            let output = try await fetchUsageFromDocker(profile: profile, accounts: snapshot.accounts)
            await cache.set(profileName: profile.name, output: output)
            let entry = await cache.getAny(profileName: profile.name)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output ?? output,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        } catch {
            let entry = await cache.getAny(profileName: profile.name)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Internals

    private func fetchUsageFromDocker(profile: UsageProfile, accounts: [UsageAccount]) async throws -> CheckUsageOutput {
        let scriptURL = try Self.vendoredScriptURL()
        let tempHomeURL = try buildTempHome(profile: profile, accounts: accounts)
        defer { try? FileManager.default.removeItem(at: tempHomeURL) }

        try stageVendoredScript(into: tempHomeURL, scriptURL: scriptURL)

        let scriptPathInContainer = "/home/node/.claude-island-scripts/check-usage.js"

        let json: Data
        do {
            json = try await runDockerCheckUsage(
                homeURL: tempHomeURL,
                scriptPathInContainer: scriptPathInContainer,
                dockerContext: nil
            )
        } catch let error as UsageFetcherError {
            // If the user has a remote Docker context selected, volume mounts will
            // not point at the local filesystem. Retry against Docker Desktop.
            if case .dockerFailed(_, let stderr) = error,
               stderr.contains("Cannot find module") || stderr.contains("MODULE_NOT_FOUND") {
                json = try await runDockerCheckUsage(
                    homeURL: tempHomeURL,
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
