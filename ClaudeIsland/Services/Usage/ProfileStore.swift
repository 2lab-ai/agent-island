import Foundation

struct UsageProfile: Codable, Equatable, Identifiable {
    let name: String
    let claudeAccountId: String?
    let codexAccountId: String?
    let geminiAccountId: String?

    var id: String { name }
}

final class ProfileStore {
    private let accountStore: AccountStore

    init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    func loadProfiles() throws -> [UsageProfile] {
        try accountStore.loadProfiles()
    }

    func saveProfiles(_ profiles: [UsageProfile]) throws {
        try accountStore.saveProfiles(profiles)
    }
}
