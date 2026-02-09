import Foundation

@main
enum UsageAccountIdentityMatcherTests {
    static func main() {
        testMatchesWhenProviderEmailsAreEqual()
        testDoesNotMatchWhenProviderEmailsDiffer()
        testIdentityKeyUsesProviderAndNormalizedEmail()
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

    private static func testIdentityKeyUsesProviderAndNormalizedEmail() {
        let a = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_aaa",
            email: " Foo@Example.com "
        )
        let b = UsageAccountIdentityMatcher.identityKey(
            service: .claude,
            accountId: "acct_claude_bbb",
            email: "foo@example.com"
        )
        assert(a == b, "Expected identity keys to match when provider+email are equal.")
    }

    private static func testIdentityKeyFallsBackToAccountIdWithoutEmail() {
        let a = UsageAccountIdentityMatcher.identityKey(
            service: .codex,
            accountId: "acct_codex_1",
            email: nil
        )
        let b = UsageAccountIdentityMatcher.identityKey(
            service: .codex,
            accountId: "acct_codex_2",
            email: nil
        )
        assert(a != b, "Expected identity keys to use accountId when email is unavailable.")
    }
}
