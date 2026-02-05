import Foundation

actor UsageCache {
    struct Entry: Sendable {
        let output: CheckUsageOutput
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func getFresh(profileName: String, now: Date = Date()) -> Entry? {
        guard let entry = entries[profileName] else { return nil }
        if now.timeIntervalSince(entry.fetchedAt) > ttl {
            return nil
        }
        return entry
    }

    func getAny(profileName: String) -> Entry? {
        entries[profileName]
    }

    func set(profileName: String, output: CheckUsageOutput, fetchedAt: Date = Date()) {
        entries[profileName] = Entry(output: output, fetchedAt: fetchedAt)
    }

    func clear(profileName: String) {
        entries.removeValue(forKey: profileName)
    }

    func clearAll() {
        entries.removeAll()
    }
}
