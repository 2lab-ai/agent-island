import Foundation

enum UsageService: String, Codable {
    case claude
    case codex
    case gemini
}

struct UsageAccount: Codable, Equatable, Identifiable {
    let id: String
    let service: UsageService
    let label: String
    let rootPath: String
    let updatedAt: Date
}

struct AccountsSnapshot: Codable {
    var accounts: [UsageAccount]
    var profiles: [UsageProfile]
}

final class AccountStore {
    private let rootDir: URL

    init(rootDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-island")) {
        self.rootDir = rootDir
    }

    private var fileURL: URL {
        rootDir.appendingPathComponent("accounts.json")
    }

    func loadSnapshot() throws -> AccountsSnapshot {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return AccountsSnapshot(accounts: [], profiles: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountsSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: AccountsSnapshot) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func loadProfiles() throws -> [UsageProfile] {
        try loadSnapshot().profiles
    }

    func saveProfiles(_ profiles: [UsageProfile]) throws {
        var snapshot = try loadSnapshot()
        snapshot.profiles = profiles
        try saveSnapshot(snapshot)
    }
}
