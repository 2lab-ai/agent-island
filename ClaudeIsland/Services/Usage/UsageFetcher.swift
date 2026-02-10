import CryptoKit
import Foundation

struct UsageIdentities: Sendable {
    let claudeEmail: String?
    let claudeTier: String?
    let claudeIsTeam: Bool?
    let codexEmail: String?
    let geminiEmail: String?

    static let empty = UsageIdentities(
        claudeEmail: nil,
        claudeTier: nil,
        claudeIsTeam: nil,
        codexEmail: nil,
        geminiEmail: nil
    )
}

struct TokenRefreshInfo: Sendable {
    let expiresAt: Date
    let lifetimeSeconds: TimeInterval
}

struct UsageTokenRefresh: Sendable {
    let claude: TokenRefreshInfo?
    let codex: TokenRefreshInfo?
    let gemini: TokenRefreshInfo?

    static let empty = UsageTokenRefresh(claude: nil, codex: nil, gemini: nil)
}

struct UsageSnapshot: Sendable, Identifiable {
    let profileName: String
    let output: CheckUsageOutput?
    let identities: UsageIdentities
    let tokenRefresh: UsageTokenRefresh
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
    typealias DockerCheckUsageRunner = (URL, String, String?) async throws -> Data

    private let accountStore: AccountStore
    private let cache: UsageCache
    private let dockerImage: String
    private let dockerRunner: DockerCheckUsageRunner?
    private let homeDirectory: URL
    private let refreshLogWriter: UsageRefreshLogWriter
    private let identityCache = IdentityCache()

    init(
        accountStore: AccountStore = AccountStore(),
        cache: UsageCache = UsageCache(),
        dockerImage: String = "node:20-alpine",
        dockerRunner: DockerCheckUsageRunner? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.accountStore = accountStore
        self.cache = cache
        self.dockerImage = dockerImage
        self.dockerRunner = dockerRunner
        self.homeDirectory = homeDirectory
        self.refreshLogWriter = UsageRefreshLogWriter(homeDirectory: homeDirectory)
    }

    func fetchSnapshot(for profile: UsageProfile, forceRefresh: Bool = false) async -> UsageSnapshot {
        var tokenRefresh = UsageTokenRefresh.empty
        var cachedIdentities = UsageIdentities.empty
        var identityKey = "profile:\(profile.name)"
        var accounts: [UsageAccount] = []

        do {
            let snapshot = try accountStore.loadSnapshot()
            accounts = snapshot.accounts
            let credentials = loadCredentials(profile: profile, accounts: snapshot.accounts)
            identityKey = identityCacheKey(namespace: "profile:\(profile.name)", credentials: credentials)

            tokenRefresh = resolveTokenRefresh(credentials: credentials)
            cachedIdentities = await resolveIdentitiesCached(key: identityKey, credentials: credentials)

            if !forceRefresh, let entry = await cache.getFresh(profileName: profile.name) {
                return UsageSnapshot(
                    profileName: profile.name,
                    output: entry.output,
                    identities: cachedIdentities,
                    tokenRefresh: tokenRefresh,
                    fetchedAt: entry.fetchedAt,
                    isStale: false,
                    errorMessage: nil
                )
            }

            let output = try await fetchUsageFromDocker(profile: profile, accounts: snapshot.accounts)
            let refreshedCredentials = loadCredentials(profile: profile, accounts: snapshot.accounts)
            tokenRefresh = resolveTokenRefresh(credentials: refreshedCredentials)

            await cache.set(profileName: profile.name, output: output)
            let entry = await cache.getAny(profileName: profile.name)
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output ?? output,
                identities: cachedIdentities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        } catch {
            if !accounts.isEmpty {
                let latestCredentials = loadCredentials(profile: profile, accounts: accounts)
                tokenRefresh = resolveTokenRefresh(credentials: latestCredentials)
            }

            let entry = await cache.getAny(profileName: profile.name)
            let identities = await identityCache.getFresh(key: identityKey) ?? cachedIdentities
            return UsageSnapshot(
                profileName: profile.name,
                output: entry?.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    func fetchCurrentSnapshot(credentials: ExportCredentials, forceRefresh: Bool = false) async -> UsageSnapshot {
        let cacheKey = "__current__"
        let profileName = "Current"
        let identityKey = identityCacheKey(namespace: cacheKey, credentials: credentials)

        var tokenRefresh = resolveTokenRefresh(credentials: credentials)
        let identities = await resolveIdentitiesCached(key: identityKey, credentials: credentials)

        if !forceRefresh, let entry = await cache.getFresh(profileName: cacheKey) {
            return UsageSnapshot(
                profileName: profileName,
                output: entry.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        }

        do {
            let output = try await fetchUsageFromDocker(credentials: credentials)
            tokenRefresh = resolveTokenRefresh(credentials: loadCurrentCredentialsFromHome())

            await cache.set(profileName: cacheKey, output: output)
            let entry = await cache.getAny(profileName: cacheKey)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output ?? output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: false,
                errorMessage: nil
            )
        } catch {
            tokenRefresh = resolveTokenRefresh(credentials: loadCurrentCredentialsFromHome())

            let entry = await cache.getAny(profileName: cacheKey)
            return UsageSnapshot(
                profileName: profileName,
                output: entry?.output,
                identities: identities,
                tokenRefresh: tokenRefresh,
                fetchedAt: entry?.fetchedAt,
                isStale: entry != nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Internals

    private struct TempHomeBuildResult {
        let homeURL: URL
        let syncTargets: [CredentialSyncTarget]
    }

    private struct CredentialSyncTarget {
        let relativePath: String
        let destinationURL: URL
    }

    private func fetchUsageFromDocker(profile: UsageProfile, accounts: [UsageAccount]) async throws -> CheckUsageOutput {
        let traceID = UUID().uuidString.lowercased()
        let build = try buildTempHome(profile: profile, accounts: accounts)
        defer { try? FileManager.default.removeItem(at: build.homeURL) }
        logRefresh(event: "refresh_cycle_started", fields: [
            "trace_id": traceID,
            "scope": "profile",
            "profile_name": profile.name,
            "claude_account_id": profile.claudeAccountId,
            "codex_account_id": profile.codexAccountId,
            "gemini_account_id": profile.geminiAccountId,
            "temp_home": build.homeURL.path,
        ])

        do {
            let output = try await fetchUsageFromDocker(homeURL: build.homeURL, traceID: traceID)
            try persistUpdatedCredentials(from: build.homeURL, targets: build.syncTargets, traceID: traceID, reason: "success")
            logRefresh(event: "refresh_cycle_completed", fields: [
                "trace_id": traceID,
                "scope": "profile",
                "result": "success",
            ])
            return output
        } catch {
            try? persistUpdatedCredentials(from: build.homeURL, targets: build.syncTargets, traceID: traceID, reason: "error")
            logRefresh(event: "refresh_cycle_completed", fields: [
                "trace_id": traceID,
                "scope": "profile",
                "result": "error",
                "error": String(describing: error),
            ])
            throw error
        }
    }

    private func fetchUsageFromDocker(credentials: ExportCredentials) async throws -> CheckUsageOutput {
        let traceID = UUID().uuidString.lowercased()
        let build = try buildTempHome(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: build.homeURL) }
        var fields: [String: String?] = [
            "trace_id": traceID,
            "scope": "current",
            "temp_home": build.homeURL.path,
        ]
        let fileClaude = claudeTokenFingerprint(from: credentials.claude)
        fields["current_claude_file_refresh_fp"] = fileClaude.refreshFingerprint
        fields["current_claude_file_access_fp"] = fileClaude.accessFingerprint
        fields["current_claude_file_expires_at"] = fileClaude.expiresAtISO8601
        let keychainClaude = claudeTokenFingerprint(from: readClaudeKeychainCredentials())
        fields["current_claude_keychain_refresh_fp"] = keychainClaude.refreshFingerprint
        fields["current_claude_keychain_access_fp"] = keychainClaude.accessFingerprint
        fields["current_claude_keychain_expires_at"] = keychainClaude.expiresAtISO8601
        logRefresh(event: "refresh_cycle_started", fields: fields)

        do {
            let output = try await fetchUsageFromDocker(homeURL: build.homeURL, traceID: traceID)
            try persistUpdatedCredentials(from: build.homeURL, targets: build.syncTargets, traceID: traceID, reason: "success")
            logRefresh(event: "refresh_cycle_completed", fields: [
                "trace_id": traceID,
                "scope": "current",
                "result": "success",
            ])
            return output
        } catch {
            try? persistUpdatedCredentials(from: build.homeURL, targets: build.syncTargets, traceID: traceID, reason: "error")
            logRefresh(event: "refresh_cycle_completed", fields: [
                "trace_id": traceID,
                "scope": "current",
                "result": "error",
                "error": String(describing: error),
            ])
            throw error
        }
    }

    private func fetchUsageFromDocker(homeURL: URL, traceID: String) async throws -> CheckUsageOutput {
        let scriptPathInContainer = "/home/node/.agent-island-scripts/check-usage.js"
        if dockerRunner == nil {
            let scriptURL = try Self.vendoredScriptURL()
            try stageVendoredScript(into: homeURL, scriptURL: scriptURL)
        }

        let runner: DockerCheckUsageRunner = dockerRunner ?? { [self] homeURL, scriptPathInContainer, dockerContext in
            try await runDockerCheckUsage(
                homeURL: homeURL,
                scriptPathInContainer: scriptPathInContainer,
                dockerContext: dockerContext,
                traceID: traceID
            )
        }

        let json: Data
        do {
            json = try await runner(homeURL, scriptPathInContainer, nil)
        } catch let error as UsageFetcherError {
            if case .dockerFailed(_, let stderr) = error,
               stderr.contains("Cannot find module") || stderr.contains("MODULE_NOT_FOUND") {
                logRefresh(event: "docker_context_retry", fields: [
                    "trace_id": traceID,
                    "reason": "module_not_found",
                    "retry_context": "desktop-linux",
                ])
                json = try await runner(homeURL, scriptPathInContainer, "desktop-linux")
            } else {
                throw error
            }
        }

        do {
            return try Self.decodeUsageOutput(json)
        } catch {
            logRefresh(event: "docker_json_decode_failed", fields: [
                "trace_id": traceID,
                "error": String(describing: error),
                "output_prefix": String(data: json.prefix(800), encoding: .utf8),
            ])
            throw UsageFetcherError.invalidJSON(underlying: error)
        }
    }

    static func vendoredScriptURL(bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: "check-usage", withExtension: "js") {
            return url
        }
        throw UsageFetcherError.vendoredScriptNotFound
    }

    private func buildTempHome(profile: UsageProfile, accounts: [UsageAccount]) throws -> TempHomeBuildResult {
        let root = homeDirectory
            .appendingPathComponent(".agent-island/tmp-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let tempHome = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        var syncTargets: [CredentialSyncTarget] = []

        try copyServiceDir(
            service: .claude,
            accountId: profile.claudeAccountId,
            accounts: accounts,
            toHome: tempHome
        )
        if let target = accountSyncTarget(service: .claude, accountId: profile.claudeAccountId, accounts: accounts) {
            syncTargets.append(target)
        }

        try copyServiceDir(
            service: .codex,
            accountId: profile.codexAccountId,
            accounts: accounts,
            toHome: tempHome
        )
        if let target = accountSyncTarget(service: .codex, accountId: profile.codexAccountId, accounts: accounts) {
            syncTargets.append(target)
        }

        try copyServiceDir(
            service: .gemini,
            accountId: profile.geminiAccountId,
            accounts: accounts,
            toHome: tempHome
        )
        if let target = accountSyncTarget(service: .gemini, accountId: profile.geminiAccountId, accounts: accounts) {
            syncTargets.append(target)
        }

        return TempHomeBuildResult(homeURL: tempHome, syncTargets: syncTargets)
    }

    private func buildTempHome(credentials: ExportCredentials) throws -> TempHomeBuildResult {
        if credentials.claude == nil, credentials.codex == nil, credentials.gemini == nil {
            throw UsageFetcherError.noCredentialsFound
        }

        let root = homeDirectory
            .appendingPathComponent(".agent-island/tmp-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let tempHome = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        let activeHome = homeDirectory
        var syncTargets: [CredentialSyncTarget] = []

        if let claudeData = credentials.claude {
            let dir = tempHome.appendingPathComponent(".claude", isDirectory: true)
            try writeFile(data: claudeData, to: dir.appendingPathComponent(".credentials.json"))
            syncTargets.append(
                CredentialSyncTarget(
                    relativePath: credentialRelativePath(for: .claude),
                    destinationURL: activeHome.appendingPathComponent(credentialRelativePath(for: .claude))
                )
            )
        }

        if let codexData = credentials.codex {
            let dir = tempHome.appendingPathComponent(".codex", isDirectory: true)
            try writeFile(data: codexData, to: dir.appendingPathComponent("auth.json"))
            syncTargets.append(
                CredentialSyncTarget(
                    relativePath: credentialRelativePath(for: .codex),
                    destinationURL: activeHome.appendingPathComponent(credentialRelativePath(for: .codex))
                )
            )
        }

        if let geminiData = credentials.gemini {
            let dir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
            try writeFile(data: geminiData, to: dir.appendingPathComponent("oauth_creds.json"))
            syncTargets.append(
                CredentialSyncTarget(
                    relativePath: credentialRelativePath(for: .gemini),
                    destinationURL: activeHome.appendingPathComponent(credentialRelativePath(for: .gemini))
                )
            )
        }

        return TempHomeBuildResult(homeURL: tempHome, syncTargets: syncTargets)
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

    private func accountSyncTarget(
        service: UsageService,
        accountId: String?,
        accounts: [UsageAccount]
    ) -> CredentialSyncTarget? {
        guard let accountId else { return nil }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return nil }

        let relativePath = credentialRelativePath(for: service)
        let accountRoot = URL(fileURLWithPath: account.rootPath, isDirectory: true)
        return CredentialSyncTarget(
            relativePath: relativePath,
            destinationURL: accountRoot.appendingPathComponent(relativePath)
        )
    }

    private func credentialRelativePath(for service: UsageService) -> String {
        switch service {
        case .claude:
            return ".claude/.credentials.json"
        case .codex:
            return ".codex/auth.json"
        case .gemini:
            return ".gemini/oauth_creds.json"
        }
    }

    private func persistUpdatedCredentials(
        from homeURL: URL,
        targets: [CredentialSyncTarget],
        traceID: String,
        reason: String
    ) throws {
        logRefresh(event: "credential_sync_started", fields: [
            "trace_id": traceID,
            "reason": reason,
            "target_count": String(targets.count),
        ])

        for target in targets {
            let sourceURL = homeURL.appendingPathComponent(target.relativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                logRefresh(event: "credential_sync_skipped", fields: [
                    "trace_id": traceID,
                    "reason": reason,
                    "decision": "missing_source",
                    "relative_path": target.relativePath,
                    "destination_path": target.destinationURL.path,
                ])
                continue
            }

            let sourceData = try Data(contentsOf: sourceURL)
            let existingData = try? Data(contentsOf: target.destinationURL)
            if let existingData, existingData == sourceData {
                logRefresh(event: "credential_sync_skipped", fields: [
                    "trace_id": traceID,
                    "reason": reason,
                    "decision": "unchanged",
                    "relative_path": target.relativePath,
                    "destination_path": target.destinationURL.path,
                ])
                continue
            }

            let decision = credentialSyncDecision(
                relativePath: target.relativePath,
                reason: reason,
                sourceData: sourceData,
                destinationData: existingData
            )

            switch decision {
            case .skip(let detail):
                var fields: [String: String?] = [
                    "trace_id": traceID,
                    "reason": reason,
                    "decision": "skipped",
                    "decision_detail": detail,
                    "relative_path": target.relativePath,
                    "destination_path": target.destinationURL.path,
                ]
                appendClaudeSyncFingerprints(
                    into: &fields,
                    sourceData: sourceData,
                    destinationData: existingData
                )
                logRefresh(event: "credential_sync_skipped", fields: fields)
            case .write(let detail):
                try writeFile(data: sourceData, to: target.destinationURL)
                var fields: [String: String?] = [
                    "trace_id": traceID,
                    "reason": reason,
                    "decision": "written",
                    "decision_detail": detail,
                    "relative_path": target.relativePath,
                    "destination_path": target.destinationURL.path,
                ]
                appendClaudeSyncFingerprints(
                    into: &fields,
                    sourceData: sourceData,
                    destinationData: existingData
                )
                logRefresh(event: "credential_sync_written", fields: fields)
            }
        }

        logRefresh(event: "credential_sync_completed", fields: [
            "trace_id": traceID,
            "reason": reason,
        ])
    }

    private enum CredentialSyncDecision {
        case write(String)
        case skip(String)
    }

    private func credentialSyncDecision(
        relativePath: String,
        reason: String,
        sourceData: Data,
        destinationData: Data?
    ) -> CredentialSyncDecision {
        if reason == "success" {
            return .write("success_path")
        }

        guard let destinationData else {
            return .write("destination_missing_on_error")
        }

        if !relativePath.hasPrefix(".claude/") {
            return .skip("non_claude_error_guard")
        }

        let source = claudeTokenFingerprint(from: sourceData)
        let destination = claudeTokenFingerprint(from: destinationData)

        if source.refreshFingerprint == destination.refreshFingerprint {
            return .write("same_refresh_fingerprint_on_error")
        }

        if let sourceExpiry = source.expiresAt,
           let destinationExpiry = destination.expiresAt,
           sourceExpiry.timeIntervalSince(destinationExpiry) > 300 {
            return .write("newer_expiry_on_error")
        }

        return .skip("claude_refresh_guard_rejected")
    }

    private func appendClaudeSyncFingerprints(
        into fields: inout [String: String?],
        sourceData: Data?,
        destinationData: Data?
    ) {
        let source = claudeTokenFingerprint(from: sourceData)
        let destination = claudeTokenFingerprint(from: destinationData)
        fields["source_refresh_fp"] = source.refreshFingerprint
        fields["source_access_fp"] = source.accessFingerprint
        fields["source_expires_at"] = source.expiresAtISO8601
        fields["destination_refresh_fp"] = destination.refreshFingerprint
        fields["destination_access_fp"] = destination.accessFingerprint
        fields["destination_expires_at"] = destination.expiresAtISO8601
    }

    private func stageVendoredScript(into homeURL: URL, scriptURL: URL) throws {
        let scriptsDir = homeURL.appendingPathComponent(".agent-island-scripts", isDirectory: true)
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
        dockerContext: String?,
        traceID: String
    ) async throws -> Data {

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let startedAt = Date()
        let logWriter = refreshLogWriter

        let sanitizeLog: (String) -> String? = { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.count <= 20_000 { return trimmed }
            let prefix = trimmed.prefix(20_000)
            return "\(prefix)…[truncated \(trimmed.count - 20_000) chars]"
        }

        let dockerExecutable = resolveDockerExecutablePath()
        process.executableURL = URL(fileURLWithPath: dockerExecutable)

        var arguments: [String] = []
        if dockerExecutable == "/usr/bin/env" {
            arguments.append("docker")
        }

        if let dockerContext {
            arguments.append(contentsOf: ["--context", dockerContext])
        }
        arguments.append(contentsOf: [
            "run",
            "--rm",
            "--user", "node",
            "--env", "HOME=/home/node",
            "--env", "DEBUG=1",
            "--volume", "\(homeURL.path):/home/node",
            dockerImage,
            "node", scriptPathInContainer, "--json",
        ])

        logWriter.write(event: "docker_run_started", fields: [
            "trace_id": traceID,
            "docker_context": dockerContext ?? "default",
            "docker_executable": dockerExecutable,
            "docker_image": dockerImage,
            "home_path": homeURL.path,
            "arguments": arguments.joined(separator: " "),
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
                let durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)

                if proc.terminationStatus == 0 {
                    Task { @MainActor in
                        logWriter.write(event: "docker_run_completed", fields: [
                            "trace_id": traceID,
                            "docker_context": dockerContext ?? "default",
                            "result": "success",
                            "exit_code": String(proc.terminationStatus),
                            "duration_ms": String(durationMS),
                            "stdout_bytes": String(outData.count),
                            "stderr_bytes": String(errData.count),
                            "stderr": sanitizeLog(stderr),
                        ])
                    }
                    continuation.resume(returning: outData)
                } else {
                    Task { @MainActor in
                        logWriter.write(event: "docker_run_completed", fields: [
                            "trace_id": traceID,
                            "docker_context": dockerContext ?? "default",
                            "result": "error",
                            "exit_code": String(proc.terminationStatus),
                            "duration_ms": String(durationMS),
                            "stdout_bytes": String(outData.count),
                            "stderr_bytes": String(errData.count),
                            "stderr": sanitizeLog(stderr),
                        ])
                    }
                    continuation.resume(
                        throwing: UsageFetcherError.dockerFailed(exitCode: proc.terminationStatus, stderr: stderr)
                    )
                }
            }

            do {
                try process.run()
            } catch {
                logWriter.write(event: "docker_run_launch_failed", fields: [
                    "trace_id": traceID,
                    "docker_context": dockerContext ?? "default",
                    "error": String(describing: error),
                ])
                continuation.resume(throwing: error)
            }
        }
    }

    // Resolve Docker CLI path for GUI app launches where PATH is often minimal.
    private func resolveDockerExecutablePath() -> String {
        let fm = FileManager.default

        if let overrideRaw = Foundation.ProcessInfo.processInfo.environment["AGENT_ISLAND_DOCKER_PATH"] {
            let override = overrideRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !override.isEmpty, fm.isExecutableFile(atPath: override) {
                return override
            }
        }

        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/Docker.app/Contents/MacOS/com.docker.cli",
            homeDirectory.appendingPathComponent(".docker/bin/docker").path,
        ]

        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }

        if let shellPath = dockerPathFromLoginShell(),
           fm.isExecutableFile(atPath: shellPath) {
            return shellPath
        }

        if let whichPath = dockerPathFromInteractiveShell(command: "which docker"),
           fm.isExecutableFile(atPath: whichPath) {
            return whichPath
        }

        if let wherePath = dockerPathFromInteractiveShell(command: "where docker"),
           fm.isExecutableFile(atPath: wherePath) {
            return wherePath
        }

        return "/usr/bin/env"
    }

    private func dockerPathFromLoginShell() -> String? {
        dockerPathFromShell(command: "command -v docker", shellModeFlag: "-lc")
    }

    // Final fallback for GUI launches: interactive shell lookup requested by user.
    private func dockerPathFromInteractiveShell(command: String) -> String? {
        dockerPathFromShell(command: command, shellModeFlag: "-ic")
    }

    private func dockerPathFromShell(command: String, shellModeFlag: String) -> String? {
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [shellModeFlag, command]
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return firstExecutablePath(in: raw)
    }

    private func firstExecutablePath(in rawOutput: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))
        for component in rawOutput.components(separatedBy: separators) {
            let candidate = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate.hasPrefix("/") else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private struct ClaudeTokenFingerprint {
        let refreshFingerprint: String?
        let accessFingerprint: String?
        let expiresAtISO8601: String?
        let expiresAt: Date?
    }

    private func logRefresh(event: String, fields: [String: String?]) {
        refreshLogWriter.write(event: event, fields: fields)
    }

    private func sanitizedLogString(_ value: String?, maxLength: Int = 20_000) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength { return trimmed }

        let prefix = trimmed.prefix(maxLength)
        return "\(prefix)…[truncated \(trimmed.count - maxLength) chars]"
    }

    private func claudeTokenFingerprint(from data: Data?) -> ClaudeTokenFingerprint {
        guard let data else {
            return ClaudeTokenFingerprint(
                refreshFingerprint: nil,
                accessFingerprint: nil,
                expiresAtISO8601: nil,
                expiresAt: nil
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeTokenFingerprint(
                refreshFingerprint: nil,
                accessFingerprint: nil,
                expiresAtISO8601: nil,
                expiresAt: nil
            )
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let refreshToken = oauth["refreshToken"] as? String
        let accessToken = oauth["accessToken"] as? String
        let expiresAt = parseDateFromAny(oauth["expiresAt"])
            ?? parseDateFromAny(oauth["expires_at"])
            ?? parseDateFromAny(root["expiresAt"])
            ?? parseDateFromAny(root["expires_at"])

        return ClaudeTokenFingerprint(
            refreshFingerprint: tokenFingerprint(refreshToken),
            accessFingerprint: tokenFingerprint(accessToken),
            expiresAtISO8601: iso8601String(expiresAt),
            expiresAt: expiresAt
        )
    }

    private func tokenFingerprint(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func iso8601String(_ date: Date?) -> String? {
        guard let date else { return nil }
        return UsageRefreshLogWriter.iso8601Formatter.string(from: date)
    }

    private func readClaudeKeychainCredentials() -> Data? {
        guard let value = readKeychain(service: "Claude Code-credentials") else { return nil }
        return Data(value.utf8)
    }

    private func readKeychain(service: String, account: String? = nil) -> String? {
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")

        guard let result = runCommand(executable: "/usr/bin/security", arguments: arguments) else {
            return nil
        }

        if result.status != 0 {
            logRefresh(event: "keychain_read_failed", fields: [
                "service": service,
                "account": account,
                "exit_code": String(result.status),
                "stderr": sanitizedLogString(result.stderr),
            ])
            return nil
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runCommand(executable: String, arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    func shouldReuseCachedIdentities(_ identities: UsageIdentities, credentials: ExportCredentials) -> Bool {
        if credentials.claude != nil, identities.claudeEmail == nil {
            return false
        }

        if credentials.codex != nil, identities.codexEmail == nil {
            return false
        }

        if credentials.gemini != nil, identities.geminiEmail == nil {
            return false
        }

        return true
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
    func identityCacheKey(namespace: String, credentials: ExportCredentials) -> String {
        "\(namespace)|claude:\(stableDataHash(credentials.claude))|codex:\(stableDataHash(credentials.codex))|gemini:\(stableDataHash(credentials.gemini))"
    }

    // Lightweight in-memory hash for cache keying; avoids reusing identities across credential changes.
    func stableDataHash(_ data: Data?) -> String {
        guard let data else { return "-" }
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    func resolveIdentitiesCached(key: String, credentials: ExportCredentials) async -> UsageIdentities {
        if let cached = await identityCache.getFresh(key: key),
           shouldReuseCachedIdentities(cached, credentials: credentials) {
            return cached
        }
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

    func loadCurrentCredentialsFromHome() -> ExportCredentials {
        let home = homeDirectory

        func read(_ relativePath: String) -> Data? {
            let path = home.appendingPathComponent(relativePath)
            return try? Data(contentsOf: path)
        }

        return ExportCredentials(
            claude: read(".claude/.credentials.json"),
            codex: read(".codex/auth.json"),
            gemini: read(".gemini/oauth_creds.json")
        )
    }

    func resolveIdentities(credentials: ExportCredentials) async -> UsageIdentities {
        async let claudeProfileTask = resolveClaudeProfile(credentials: credentials.claude)
        let codexEmail = resolveJWTEmail(credentials: credentials.codex)
        let geminiEmail = resolveJWTEmail(credentials: credentials.gemini)
        let claudeProfile = await claudeProfileTask

        return UsageIdentities(
            claudeEmail: claudeProfile.email,
            claudeTier: claudeProfile.tier,
            claudeIsTeam: claudeProfile.isTeam,
            codexEmail: codexEmail,
            geminiEmail: geminiEmail
        )
    }

    struct ClaudeProfile: Sendable {
        let email: String?
        let tier: String?
        let isTeam: Bool?
    }

    struct ClaudeCredentialMetadata {
        let email: String?
        let tier: String?
        let isTeam: Bool?
    }

    func resolveClaudeProfile(credentials: Data?) async -> ClaudeProfile {
        let metadata = resolveClaudeCredentialMetadata(credentials: credentials)

        guard let token = extractClaudeAccessToken(credentials: credentials) else {
            return ClaudeProfile(
                email: metadata.email,
                tier: metadata.tier,
                isTeam: metadata.isTeam
            )
        }

        let profile = await fetchClaudeProfile(accessToken: token)
        return ClaudeProfile(
            email: profile.email ?? metadata.email,
            tier: profile.tier ?? metadata.tier,
            isTeam: profile.isTeam ?? metadata.isTeam
        )
    }

    func resolveClaudeCredentialMetadata(credentials: Data?) -> ClaudeCredentialMetadata {
        guard let credentials else {
            return ClaudeCredentialMetadata(email: nil, tier: nil, isTeam: nil)
        }

        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else {
            return ClaudeCredentialMetadata(email: nil, tier: nil, isTeam: nil)
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]

        let email: String? = {
            if let account = root["account"] as? [String: Any],
               let raw = account["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let account = oauth["account"] as? [String: Any],
               let raw = account["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let raw = root["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            if let raw = oauth["email"] as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            return nil
        }()

        let subscriptionType = normalizedString(oauth["subscriptionType"])
            ?? normalizedString(root["subscriptionType"])
        let rateLimitTier = normalizedString(oauth["rateLimitTier"])
            ?? normalizedString(root["rateLimitTier"])
        let tier = resolveClaudeTier(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
        let isTeam = resolveClaudeIsTeam(root: root, oauth: oauth, subscriptionType: subscriptionType)

        return ClaudeCredentialMetadata(email: email, tier: tier, isTeam: isTeam)
    }

    func resolveClaudeTier(subscriptionType: String?, rateLimitTier: String?) -> String? {
        if let rateLimitTier,
           let normalized = normalizeClaudeTier(string: rateLimitTier) {
            return normalized
        }

        guard let subscriptionType else { return nil }
        let lowered = subscriptionType.lowercased()
        if lowered.contains("pro") { return "Pro" }
        if lowered.contains("max") { return "Max" }
        return nil
    }

    func resolveClaudeIsTeam(root: [String: Any], oauth: [String: Any], subscriptionType: String?) -> Bool? {
        if let org = root["organization"] as? [String: Any],
           let orgType = org["organization_type"] as? String {
            return orgType.lowercased().contains("team")
        }

        if let org = oauth["organization"] as? [String: Any],
           let orgType = org["organization_type"] as? String {
            return orgType.lowercased().contains("team")
        }

        if let bool = parseBoolean(oauth["isTeam"]) ?? parseBoolean(root["isTeam"]) {
            return bool
        }

        if let subscriptionType {
            return subscriptionType.lowercased().contains("team")
        }

        return nil
    }

    // MARK: - Token Refresh

    func resolveTokenRefresh(credentials: ExportCredentials) -> UsageTokenRefresh {
        UsageTokenRefresh(
            claude: resolveClaudeTokenRefresh(credentials: credentials.claude),
            codex: resolveJWTTokenRefresh(credentials: credentials.codex, defaultLifetimeSeconds: 24 * 60 * 60),
            gemini: resolveGeminiTokenRefresh(credentials: credentials.gemini)
        )
    }

    func resolveClaudeTokenRefresh(credentials: Data?) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let expiresAt = parseDateFromAny(oauth["expiresAt"])
            ?? parseDateFromAny(oauth["expires_at"])
            ?? parseDateFromAny(oauth["expiresAtMs"])
            ?? parseDateFromAny(oauth["expires_at_ms"])
            ?? parseDateFromAny(oauth["expiresAtSeconds"])
            ?? parseDateFromAny(oauth["expires_at_seconds"])
            ?? parseDateFromAny(root["expiresAt"])
            ?? parseDateFromAny(root["expires_at"])

        if let expiresAt {
            let issuedAt = parseDateFromAny(oauth["issuedAt"])
                ?? parseDateFromAny(oauth["issued_at"])
                ?? parseDateFromAny(root["issuedAt"])
                ?? parseDateFromAny(root["issued_at"])

            let lifetime = computeLifetimeSeconds(
                expiresAt: expiresAt,
                issuedAt: issuedAt,
                defaultLifetimeSeconds: 60 * 60
            )
            return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
        }

        if let token = oauth["accessToken"] as? String {
            return decodeJWTPayloadTokenRefresh(fromToken: token, defaultLifetimeSeconds: 60 * 60)
        }

        return nil
    }

    func resolveJWTTokenRefresh(credentials: Data?, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }
        return findJWTTokenRefresh(in: root, defaultLifetimeSeconds: defaultLifetimeSeconds)
    }

    func resolveGeminiTokenRefresh(credentials: Data?) -> TokenRefreshInfo? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) else { return nil }

        if let dict = root as? [String: Any] {
            let tokenDict = dict["token"] as? [String: Any] ?? [:]
            let expiresAt = parseDateFromAny(dict["expiry_date"])
                ?? parseDateFromAny(dict["expiryDate"])
                ?? parseDateFromAny(dict["expiresAt"])
                ?? parseDateFromAny(dict["expires_at"])
                ?? parseDateFromAny(tokenDict["expiresAt"])
                ?? parseDateFromAny(tokenDict["expiryDate"])
                ?? parseDateFromAny(tokenDict["expiry_date"])

            if let expiresAt {
                let issuedAt = parseDateFromAny(dict["issued_at"])
                    ?? parseDateFromAny(dict["issuedAt"])
                    ?? parseDateFromAny(tokenDict["issued_at"])
                    ?? parseDateFromAny(tokenDict["issuedAt"])

                let lifetime = computeLifetimeSeconds(
                    expiresAt: expiresAt,
                    issuedAt: issuedAt,
                    defaultLifetimeSeconds: 60 * 60
                )
                return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
            }
        }

        // Fallback: sometimes creds contain an ID token JWT with `exp`.
        return findJWTTokenRefresh(in: root, defaultLifetimeSeconds: 60 * 60)
    }

    func computeLifetimeSeconds(
        expiresAt: Date,
        issuedAt: Date?,
        defaultLifetimeSeconds: TimeInterval
    ) -> TimeInterval {
        guard let issuedAt else { return defaultLifetimeSeconds }
        let computed = expiresAt.timeIntervalSince(issuedAt)
        if computed.isFinite, computed > 0 { return computed }
        return defaultLifetimeSeconds
    }

    func parseDateFromAny(_ value: Any?) -> Date? {
        guard let value else { return nil }

        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return dateFromTimestamp(number.doubleValue) }
        if let double = value as? Double { return dateFromTimestamp(double) }
        if let int = value as? Int { return dateFromTimestamp(Double(int)) }

        if let string = value as? String {
            if let number = Double(string) {
                return dateFromTimestamp(number)
            }

            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
        }

        return nil
    }

    func dateFromTimestamp(_ timestamp: Double) -> Date? {
        guard timestamp.isFinite, timestamp > 0 else { return nil }

        if timestamp > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }

        if timestamp > 1_000_000_000 {
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }

    func findJWTTokenRefresh(in object: Any, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        if let value = object as? String {
            return decodeJWTPayloadTokenRefresh(fromToken: value, defaultLifetimeSeconds: defaultLifetimeSeconds)
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let found = findJWTTokenRefresh(in: value, defaultLifetimeSeconds: defaultLifetimeSeconds) { return found }
            }
        }

        if let list = object as? [Any] {
            for value in list {
                if let found = findJWTTokenRefresh(in: value, defaultLifetimeSeconds: defaultLifetimeSeconds) { return found }
            }
        }

        return nil
    }

    func decodeJWTPayloadTokenRefresh(fromToken token: String, defaultLifetimeSeconds: TimeInterval) -> TokenRefreshInfo? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let payloadBase64URL = String(parts[1])
        guard let payloadData = decodeBase64URL(payloadBase64URL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }

        guard let expSeconds = extractNumeric(root["exp"]) else { return nil }
        let expiresAt = Date(timeIntervalSince1970: expSeconds)

        let issuedAt: Date?
        if let iatSeconds = extractNumeric(root["iat"]) {
            issuedAt = Date(timeIntervalSince1970: iatSeconds)
        } else {
            issuedAt = nil
        }

        let lifetime = computeLifetimeSeconds(
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            defaultLifetimeSeconds: defaultLifetimeSeconds
        )
        return TokenRefreshInfo(expiresAt: expiresAt, lifetimeSeconds: lifetime)
    }

    func extractNumeric(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    func normalizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parseBoolean(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = normalizedString(value) {
            let lowered = string.lowercased()
            if lowered == "true" || lowered == "1" || lowered == "yes" { return true }
            if lowered == "false" || lowered == "0" || lowered == "no" { return false }
            if lowered.contains("team") { return true }
        }
        return nil
    }

    func extractClaudeAccessToken(credentials: Data?) -> String? {
        guard let credentials else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    func fetchClaudeProfile(accessToken: String) async -> ClaudeProfile {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("agent-island", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
            }

            let email: String? = {
                if let account = root["account"] as? [String: Any] {
                    if let raw = account["email"] as? String, let extracted = extractEmailAddress(from: raw) {
                        return extracted
                    }
                }

                if let raw = root["email"] as? String, let extracted = extractEmailAddress(from: raw) {
                    return extracted
                }

                return findFirstEmailString(in: root)
            }()

            let isTeam: Bool? = {
                guard let org = root["organization"] as? [String: Any] else { return nil }
                guard let orgType = org["organization_type"] as? String else { return nil }
                return orgType.lowercased().contains("team")
            }()

            let tier = extractClaudeTier(in: root)
            return ClaudeProfile(email: email, tier: tier, isTeam: isTeam)
        } catch {
            return ClaudeProfile(email: nil, tier: nil, isTeam: nil)
        }
    }

    func extractClaudeTier(in root: [String: Any]) -> String? {
        for key in ["subscriptionTier", "subscription_tier", "planType", "plan_type", "plan", "tier", "product", "sku"] {
            if let tier = parseClaudeTier(from: root[key]) { return tier }
        }

        for key in ["subscription", "billing", "entitlements", "account"] {
            if let tier = parseClaudeTier(from: root[key]) { return tier }
        }

        return nil
    }

    func parseClaudeTier(from value: Any?) -> String? {
        if let value, let number = extractNumeric(value) {
            if let tier = normalizeClaudeTier(multiplier: number) { return tier }
        }

        if let string = value as? String {
            return normalizeClaudeTier(string: string)
        }

        if let dict = value as? [String: Any] {
            for key in ["maxMultiplier", "max_multiplier", "maxTierMultiplier", "max_tier_multiplier", "multiplier"] {
                if let number = extractNumeric(dict[key]) {
                    if let tier = normalizeClaudeTier(multiplier: number) { return tier }
                }
            }

            for key in ["tier", "plan", "plan_type", "planType", "subscriptionTier", "subscription_tier", "product", "sku", "name", "id"] {
                if let tier = parseClaudeTier(from: dict[key]) { return tier }
            }

            for value in dict.values {
                if let tier = parseClaudeTier(from: value) { return tier }
            }
        }

        if let list = value as? [Any] {
            for value in list {
                if let tier = parseClaudeTier(from: value) { return tier }
            }
        }

        return nil
    }

    func normalizeClaudeTier(multiplier: Double) -> String? {
        if abs(multiplier - 20) < 0.01 { return "Max 20x" }
        if abs(multiplier - 5) < 0.01 { return "Max 5x" }
        return nil
    }

    func normalizeClaudeTier(string: String) -> String? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if raw.contains("@") { return nil }

        let lowered = raw.lowercased()
        let tokens = lowered.split { !($0.isLetter || $0.isNumber) }
        let hasToken: (String) -> Bool = { token in tokens.contains { $0 == token } }
        let normalized = lowered
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("max20") || (hasToken("max") && (hasToken("20x") || hasToken("20"))) { return "Max 20x" }
        if normalized.contains("max5") || (hasToken("max") && (hasToken("5x") || hasToken("5"))) { return "Max 5x" }
        if hasToken("pro") { return "Pro" }

        return nil
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

        if let email = root["email"] as? String, let extracted = extractEmailAddress(from: email) { return extracted }
        if let email = root["preferred_username"] as? String, let extracted = extractEmailAddress(from: email) { return extracted }
        return findFirstEmailString(in: root)
    }

    func extractEmailAddress(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = Self.emailRegex.firstMatch(in: trimmed, options: [], range: nsRange) else { return nil }
        guard let range = Range(match.range, in: trimmed) else { return nil }
        return String(trimmed[range])
    }

    func findFirstEmailString(in object: Any) -> String? {
        if let value = object as? String, value.contains("@"), value.count < 200 {
            return extractEmailAddress(from: value)
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

    private static let emailRegex: NSRegularExpression = {
        // Pragmatic: good-enough email substring matcher for provider identity extraction.
        let pattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        // Force unwrap: pattern is static and validated in development.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

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

private final class UsageRefreshLogWriter {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let logFileURL: URL
    private let logDirURL: URL
    private let queue = DispatchQueue(label: "ai.2lab.agent-island.usage-refresh-log")
    private let maxLogBytes = 5 * 1024 * 1024

    init(homeDirectory: URL) {
        logDirURL = homeDirectory.appendingPathComponent(".agent-island/logs", isDirectory: true)
        logFileURL = logDirURL.appendingPathComponent("usage-refresh.log")
    }

    func write(event: String, fields: [String: String?]) {
        queue.async { [self] in
            do {
                try prepareLogFileIfNeeded()

                var payload: [String: String] = [
                    "timestamp": Self.iso8601Formatter.string(from: Date()),
                    "event": event,
                ]

                for (key, value) in fields {
                    guard let value else { continue }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    payload[key] = trimmed
                }

                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                guard let line = String(data: data, encoding: .utf8) else { return }
                try append(line: line)
            } catch {
                // Best-effort diagnostic logging only; never fail caller.
            }
        }
    }

    private func prepareLogFileIfNeeded() throws {
        try FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(
                atPath: logFileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if currentSize <= maxLogBytes { return }

        let rotatedURL = logDirURL.appendingPathComponent("usage-refresh.log.1")
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            try FileManager.default.removeItem(at: rotatedURL)
        }
        try FileManager.default.moveItem(at: logFileURL, to: rotatedURL)
        FileManager.default.createFile(
            atPath: logFileURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func append(line: String) throws {
        guard let payload = "\(line)\n".data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: logFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }
}
