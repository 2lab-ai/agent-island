import Foundation

@main
enum UsageAccountIdentityMatcherTests {
    static func main() {
        testMatchesWhenProviderEmailsAreEqual()
        testClaudeDoesNotMatchWhenTeamTypeDiffers()
        testDoesNotMatchWhenProviderEmailsDiffer()
        testRequiresAllProvidersToMatch()
        testIdentityKeyUsesProviderAndNormalizedEmail()
        testIdentityKeyKeepsClaudeTeamAndPersonalDistinct()
        testIdentityKeyDoesNotCollideAcrossProviders()
        testIdentityKeyFallsBackToAccountIdWithoutEmail()
        print("OK")
    }

    private static func testMatchesWhenProviderEmailsAreEqual() {
        let profile = UsageProfile(
            name: "A",
            claudeAccountId: "acct_claude_oldhash",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        let knownEmails = [
            "acct_claude_oldhash": "foo@example.com",
            "acct_claude_newhash": " Foo@Example.com "
        ]

        let matches = UsageAccountIdentityMatcher.matchesProfile(
            currentClaudeAccountId: "acct_claude_newhash",
            currentCodexAccountId: nil,
            currentGeminiAccountId: nil,
            profile: profile,
            emailByAccountId: knownEmails
        )

        assert(matches, "Expected profile to match when provider emails are equal.")
    }

    private static func testClaudeDoesNotMatchWhenTeamTypeDiffers() {
        let profile = UsageProfile(
            name: "A",
            claudeAccountId: "acct_claude_team",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        let knownEmails = [
            "acct_claude_team": "foo@example.com",
            "acct_claude_personal": "foo@example.com"
        ]
        let knownTeamFlags = [
            "acct_claude_team": true,
            "acct_claude_personal": false
        ]

        let matches = UsageAccountIdentityMatcher.matchesProfile(
            currentClaudeAccountId: "acct_claude_personal",
            currentCodexAccountId: nil,
            currentGeminiAccountId: nil,
            profile: profile,
            emailByAccountId: knownEmails,
            claudeTeamByAccountId: knownTeamFlags
        )

        assert(!matches, "Expected Claude identities not to match when team/personal type differs.")
    }

    private static func testDoesNotMatchWhenProviderEmailsDiffer() {
        let profile = UsageProfile(
            name: "A",
            claudeAccountId: "acct_claude_oldhash",
            codexAccountId: nil,
            geminiAccountId: nil
        )
        let knownEmails = [
            "acct_claude_oldhash": "foo@example.com",
            "acct_claude_newhash": "bar@example.com"
        ]

        let matches = UsageAccountIdentityMatcher.matchesProfile(
            currentClaudeAccountId: "acct_claude_newhash",
            currentCodexAccountId: nil,
            currentGeminiAccountId: nil,
            profile: profile,
            emailByAccountId: knownEmails
        )

        assert(!matches, "Expected profile not to match when provider emails differ.")
    }

    private static func testRequiresAllProvidersToMatch() {
        let profile = UsageProfile(
            name: "A",
            claudeAccountId: "acct_claude_profile",
            codexAccountId: "acct_codex_profile",
            geminiAccountId: nil
        )
        let knownEmails = [
            "acct_claude_profile": "foo@example.com",
            "acct_claude_current": "foo@example.com",
            "acct_codex_profile": "foo@example.com",
            "acct_codex_current": "bar@example.com"
        ]

        let matches = UsageAccountIdentityMatcher.matchesProfile(
            currentClaudeAccountId: "acct_claude_current",
            currentCodexAccountId: "acct_codex_current",
            currentGeminiAccountId: nil,
            profile: profile,
            emailByAccountId: knownEmails
        )

        assert(!matches, "Expected profile not to match when any provider identity mismatches.")
    }

    private static func testIdentityKeyUsesProviderAndNormalizedEmail() {
        let a = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_aaa",
            email: " Foo@Example.com ",
            claudeIsTeam: true
        )
        let b = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_bbb",
            email: "foo@example.com",
            claudeIsTeam: true
        )
        assert(a == b, "Expected identity keys to match when provider+email are equal.")
    }

    private static func testIdentityKeyKeepsClaudeTeamAndPersonalDistinct() {
        let team = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_team",
            email: "foo@example.com",
            claudeIsTeam: true
        )
        let personal = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_personal",
            email: "foo@example.com",
            claudeIsTeam: false
        )
        assert(team != personal, "Expected Claude team/personal identities to remain distinct.")
    }

    private static func testIdentityKeyDoesNotCollideAcrossProviders() {
        let claude = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_aaa",
            email: "foo@example.com",
            claudeIsTeam: true
        )
        let codex = UsageAccountIdentityMatcher.identityKey(
            service: .codex,
            accountId: "acct_codex_bbb",
            email: "foo@example.com",
            claudeIsTeam: nil
        )
        assert(claude != codex, "Expected identity keys to remain distinct across providers.")
    }

    private static func testIdentityKeyFallsBackToAccountIdWithoutEmail() {
        let a = UsageAccountIdentityMatcher.identityKey(
            service: .codex,
            accountId: "acct_codex_1",
            email: nil,
            claudeIsTeam: nil
        )
        let b = UsageAccountIdentityMatcher.identityKey(
            service: .codex,
            accountId: "acct_codex_2",
            email: nil,
            claudeIsTeam: nil
        )
        assert(a != b, "Expected identity keys to use accountId when email is unavailable.")
    }
}
