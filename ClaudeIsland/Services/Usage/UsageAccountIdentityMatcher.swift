import Foundation

enum UsageAccountIdentityMatcher {
    static func matchesProfile(
        currentClaudeAccountId: String?,
        currentCodexAccountId: String?,
        currentGeminiAccountId: String?,
        profile: UsageProfile,
        emailByAccountId: [String: String],
        claudeTeamByAccountId: [String: Bool] = [:]
    ) -> Bool {
        accountMatches(
            service: .claude,
            currentAccountId: currentClaudeAccountId,
            profileAccountId: profile.claudeAccountId,
            emailByAccountId: emailByAccountId,
            claudeTeamByAccountId: claudeTeamByAccountId
        ) &&
            accountMatches(
                service: .codex,
                currentAccountId: currentCodexAccountId,
                profileAccountId: profile.codexAccountId,
                emailByAccountId: emailByAccountId,
                claudeTeamByAccountId: claudeTeamByAccountId
            ) &&
            accountMatches(
                service: .gemini,
                currentAccountId: currentGeminiAccountId,
                profileAccountId: profile.geminiAccountId,
                emailByAccountId: emailByAccountId,
                claudeTeamByAccountId: claudeTeamByAccountId
            )
    }

    static func identityKey(service: UsageService, accountId: String, email: String?, claudeIsTeam: Bool?) -> String {
        if let normalizedEmail = normalizedEmail(email) {
            if service == .claude {
                let teamType: String
                if let claudeIsTeam {
                    teamType = claudeIsTeam ? "team" : "personal"
                } else {
                    teamType = "unknown"
                }
                return "\(service.rawValue):email:\(normalizedEmail):type:\(teamType)"
            }
            return "\(service.rawValue):email:\(normalizedEmail)"
        }
        return "\(service.rawValue):account:\(accountId)"
    }

    private static func accountMatches(
        service: UsageService,
        currentAccountId: String?,
        profileAccountId: String?,
        emailByAccountId: [String: String],
        claudeTeamByAccountId: [String: Bool]
    ) -> Bool {
        switch (currentAccountId, profileAccountId) {
        case (nil, nil):
            return true
        case let (current?, profile?):
            if current == profile { return true }

            let currentEmail = normalizedEmail(emailByAccountId[current])
            let profileEmail = normalizedEmail(emailByAccountId[profile])

            if service == .claude {
                let currentTeam = claudeTeamByAccountId[current]
                let profileTeam = claudeTeamByAccountId[profile]
                if let currentTeam, let profileTeam, currentTeam != profileTeam {
                    return false
                }
            }

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
