import Foundation

@main
enum AccountStoreTests {
    static func main() throws {
        let store = AccountStore(rootDir: URL(fileURLWithPath: "/tmp/claude-island-test"))
        let profile = UsageProfile(name: "A", claudeAccountId: "acct1", codexAccountId: nil, geminiAccountId: nil)
        try store.saveProfiles([profile])
        let loaded = try store.loadProfiles()
        assert(loaded.first?.name == "A")
        print("OK")
    }
}
