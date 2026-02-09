import Foundation

enum UsageAccountIdentityMatcher {
    static func matchesProfile(
        currentClaudeAccountId: String?,
        currentCodexAccountId: String?,
        currentGeminiAccountId: String?,
        profile: UsageProfile,
        emailByAccountId: [String: String]
    ) -> Bool {
        accountMatches(
            currentAccountId: currentClaudeAccountId,
            profileAccountId: profile.claudeAccountId,
            emailByAccountId: emailByAccountId
        ) &&
            accountMatches(
                currentAccountId: currentCodexAccountId,
                profileAccountId: profile.codexAccountId,
                emailByAccountId: emailByAccountId
            ) &&
            accountMatches(
                currentAccountId: currentGeminiAccountId,
                profileAccountId: profile.geminiAccountId,
                emailByAccountId: emailByAccountId
            )
    }

    static func identityKey(service: UsageService, accountId: String, email: String?) -> String {
        if let normalizedEmail = normalizedEmail(email) {
            return "\(service.rawValue):email:\(normalizedEmail)"
        }
        return "\(service.rawValue):account:\(accountId)"
    }

    private static func accountMatches(
        currentAccountId: String?,
        profileAccountId: String?,
        emailByAccountId: [String: String]
    ) -> Bool {
        switch (currentAccountId, profileAccountId) {
        case (nil, nil):
            return true
        case let (current?, profile?):
            if current == profile { return true }

            let currentEmail = normalizedEmail(emailByAccountId[current])
            let profileEmail = normalizedEmail(emailByAccountId[profile])
            return currentEmail != nil && currentEmail == profileEmail
        default:
            return false
        }
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
