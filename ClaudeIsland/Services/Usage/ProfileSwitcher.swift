import CryptoKit
import Foundation

enum UsageCredentialHasher {
    static func fingerprint(service: UsageService, data: Data) -> (accountId: String, hashPrefix: String) {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let hashPrefix = String(hex.prefix(16))
        return (accountId: "acct_\(service.rawValue)_\(hashPrefix)", hashPrefix: hashPrefix)
    }
}

struct ProfileSaveResult {
    let profile: UsageProfile
    let accountsWritten: [UsageAccount]
    let warnings: [String]
}

struct ProfileSwitchResult {
    let profileName: String
    let claudeSwitched: Bool
    let codexSwitched: Bool
    let geminiSwitched: Bool
    let warnings: [String]
}

enum ProfileSwitcherError: LocalizedError {
    case invalidProfileName
    case profileNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            return "Profile name is required."
        case .profileNotFound(let name):
            return "Profile not found: \(name)"
        }
    }
}

final class ProfileSwitcher {
    private let accountStore: AccountStore
    private let exporter: CredentialExporter
    private let fileManager: FileManager
    private let activeHomeDir: URL
    private let accountsDir: URL

    init(
        accountStore: AccountStore = AccountStore(),
        exporter: CredentialExporter = CredentialExporter(),
        fileManager: FileManager = .default,
        activeHomeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.accountStore = accountStore
        self.exporter = exporter
        self.fileManager = fileManager
        self.activeHomeDir = activeHomeDir
        self.accountsDir = activeHomeDir.appendingPathComponent(".claude-island/accounts", isDirectory: true)
    }

    func saveCurrentProfile(named name: String) throws -> ProfileSaveResult {
        let credentials = exporter.loadCurrentCredentials()
        return try saveProfile(named: name, credentials: credentials)
    }

    func saveProfile(named name: String, credentials: ExportCredentials) throws -> ProfileSaveResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileSwitcherError.invalidProfileName
        }

        try fileManager.createDirectory(at: accountsDir, withIntermediateDirectories: true)

        var snapshot = try accountStore.loadSnapshot()
        var warnings: [String] = []
        var accountsWritten: [UsageAccount] = []

        var profile = UsageProfile(name: trimmed, claudeAccountId: nil, codexAccountId: nil, geminiAccountId: nil)

        let now = Date()
        if let data = credentials.claude {
            let (account, written) = try writeAccount(
                service: .claude,
                data: data,
                updatedAt: now,
                snapshot: &snapshot
            )
            profile = UsageProfile(
                name: trimmed,
                claudeAccountId: account.id,
                codexAccountId: profile.codexAccountId,
                geminiAccountId: profile.geminiAccountId
            )
            if written { accountsWritten.append(account) }
        } else {
            warnings.append("Claude credentials not found")
        }

        if let data = credentials.codex {
            let (account, written) = try writeAccount(
                service: .codex,
                data: data,
                updatedAt: now,
                snapshot: &snapshot
            )
            profile = UsageProfile(
                name: trimmed,
                claudeAccountId: profile.claudeAccountId,
                codexAccountId: account.id,
                geminiAccountId: profile.geminiAccountId
            )
            if written { accountsWritten.append(account) }
        } else {
            warnings.append("Codex credentials not found")
        }

        if let data = credentials.gemini {
            let (account, written) = try writeAccount(
                service: .gemini,
                data: data,
                updatedAt: now,
                snapshot: &snapshot
            )
            profile = UsageProfile(
                name: trimmed,
                claudeAccountId: profile.claudeAccountId,
                codexAccountId: profile.codexAccountId,
                geminiAccountId: account.id
            )
            if written { accountsWritten.append(account) }
        } else {
            warnings.append("Gemini credentials not found")
        }

        upsertProfile(profile, snapshot: &snapshot)
        try accountStore.saveSnapshot(snapshot)

        return ProfileSaveResult(profile: profile, accountsWritten: accountsWritten, warnings: warnings)
    }

    func switchToProfile(named name: String) throws -> ProfileSwitchResult {
        let snapshot = try accountStore.loadSnapshot()
        guard let profile = snapshot.profiles.first(where: { $0.name == name }) else {
            throw ProfileSwitcherError.profileNotFound(name: name)
        }
        return try switchToProfile(profile, accounts: snapshot.accounts)
    }

    func switchToProfile(_ profile: UsageProfile) throws -> ProfileSwitchResult {
        let snapshot = try accountStore.loadSnapshot()
        return try switchToProfile(profile, accounts: snapshot.accounts)
    }

    // MARK: - Internals

    private func switchToProfile(_ profile: UsageProfile, accounts: [UsageAccount]) throws -> ProfileSwitchResult {
        var warnings: [String] = []
        var claudeSwitched = false
        var codexSwitched = false
        var geminiSwitched = false

        if let id = profile.claudeAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".claude/.credentials.json")
                let dst = activeHomeDir.appendingPathComponent(".claude/.credentials.json")
                if copyCredentialFileIfPresent(from: src, to: dst) {
                    claudeSwitched = true
                } else {
                    warnings.append("Claude credentials missing for account \(id)")
                }
            } else {
                warnings.append("Claude account not found: \(id)")
            }
        }

        if let id = profile.codexAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".codex/auth.json")
                let dst = activeHomeDir.appendingPathComponent(".codex/auth.json")
                if copyCredentialFileIfPresent(from: src, to: dst) {
                    codexSwitched = true
                } else {
                    warnings.append("Codex credentials missing for account \(id)")
                }
            } else {
                warnings.append("Codex account not found: \(id)")
            }
        }

        if let id = profile.geminiAccountId {
            if let account = accounts.first(where: { $0.id == id }) {
                let src = URL(fileURLWithPath: account.rootPath, isDirectory: true)
                    .appendingPathComponent(".gemini/oauth_creds.json")
                let dst = activeHomeDir.appendingPathComponent(".gemini/oauth_creds.json")
                if copyCredentialFileIfPresent(from: src, to: dst) {
                    geminiSwitched = true
                } else {
                    warnings.append("Gemini credentials missing for account \(id)")
                }
            } else {
                warnings.append("Gemini account not found: \(id)")
            }
        }

        return ProfileSwitchResult(
            profileName: profile.name,
            claudeSwitched: claudeSwitched,
            codexSwitched: codexSwitched,
            geminiSwitched: geminiSwitched,
            warnings: warnings
        )
    }

    private func upsertProfile(_ profile: UsageProfile, snapshot: inout AccountsSnapshot) {
        if let idx = snapshot.profiles.firstIndex(where: { $0.name == profile.name }) {
            snapshot.profiles[idx] = profile
        } else {
            snapshot.profiles.append(profile)
        }
    }

    private func writeAccount(
        service: UsageService,
        data: Data,
        updatedAt: Date,
        snapshot: inout AccountsSnapshot
    ) throws -> (account: UsageAccount, written: Bool) {
        let fingerprint = UsageCredentialHasher.fingerprint(service: service, data: data)
        let accountId = fingerprint.accountId
        let hashPrefix = fingerprint.hashPrefix
        let root = accountsDir.appendingPathComponent(accountId, isDirectory: true)

        let exportCredentials: ExportCredentials
        switch service {
        case .claude:
            exportCredentials = ExportCredentials(claude: data, codex: nil, gemini: nil)
        case .codex:
            exportCredentials = ExportCredentials(claude: nil, codex: data, gemini: nil)
        case .gemini:
            exportCredentials = ExportCredentials(claude: nil, codex: nil, gemini: data)
        }

        _ = try exporter.export(exportCredentials, to: root)

        let account = UsageAccount(
            id: accountId,
            service: service,
            label: "\(service.rawValue):\(hashPrefix)",
            rootPath: root.path,
            updatedAt: updatedAt
        )
        upsertAccount(account, snapshot: &snapshot)

        return (account, true)
    }

    private func upsertAccount(_ account: UsageAccount, snapshot: inout AccountsSnapshot) {
        if let idx = snapshot.accounts.firstIndex(where: { $0.id == account.id }) {
            snapshot.accounts[idx] = account
        } else {
            snapshot.accounts.append(account)
        }
    }

    private func copyCredentialFileIfPresent(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destinationURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return true
        } catch {
            return false
        }
    }
}
