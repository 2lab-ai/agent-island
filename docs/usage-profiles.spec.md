# Usage Profiles & Subscription Dashboard Spec

## Goal
Provide a default “Usage” screen that shows per-profile subscription usage (Claude, Codex, Gemini),
supports saving current credentials into reusable profiles, and isolates multi-account usage checks
through Docker without altering the user’s active login state.

## Scope
In scope:
- Default open screen becomes **Usage Dashboard**.
- Profile list with 5h/7d usage for Claude/Codex and usage for Gemini.
- Sessions preview embedded at bottom of Usage screen, linking to full sessions list.
- Menu entries: “구독 사용량”, “클로드 세션 리스트”, followed by existing items.
- Profile save flow that exports current credentials into an account store.
- Multi-account usage fetch via Docker + `claude-dashboard` script.
- Experimental “one-click profile switch” (code-only, minimal manual testing).

Out of scope (for now):
- Perfect reliability and automated tests for profile switching.
- Advanced UI theming or polished account editing UX.

## User Workflow
1. User logs into Claude, Codex, Gemini CLI.
2. User presses “Save Profile” and names profile A.
3. App exports current credentials into account roots and links them to profile A.
4. User later logs into new Claude/Codex accounts, saves profile B.
5. Profile B links new Claude/Codex accounts; Gemini remains linked to existing account if unchanged.
6. Usage dashboard shows per-profile 5h/7d usage.

## Data Model
### Accounts Store
File: `~/.claude-island/accounts.json`

- Accounts are shared across profiles.
- Account identity is derived from credentials where possible; otherwise a stable hash label is used.
- Each account has a **root path** containing service credential folders (any subset).

Example shape:
```json
{
  "accounts": {
    "acct_claude_z2lab": {
      "id": "acct_claude_z2lab",
      "service": "claude",
      "label": "z@2lab.ai",
      "rootPath": "/Users/me/.claude-island/accounts/acct_claude_z2lab",
      "updatedAt": "2026-02-05T07:00:00Z"
    }
  },
  "profiles": {
    "ProfileA": {
      "claude": "acct_claude_z2lab",
      "codex": "acct_codex_icedac",
      "gemini": "acct_gemini_icedac"
    }
  }
}
```

### Files per Account Root
- Claude: `.claude/.credentials.json`
- Codex: `.codex/auth.json`
- Gemini: `.gemini/oauth_creds.json`

## Usage Fetching
- Vendor `claude-dashboard`’s `check-usage.js` (dist build).
- Build a temporary HOME by merging `.claude/.codex/.gemini` from linked account roots.
- Run Docker:
  - Image: Node 18+ (e.g., `node:20-alpine`)
  - Mount: temp HOME and script path
  - Command: `node /app/check-usage.js --json`
- Parse JSON into UI models and cache for ~60s.

## UI Requirements
- Usage Dashboard is default open view.
- Profile rows show:
  - Profile name
  - Claude 5h/7d usage, Codex 5h/7d usage
  - Gemini usage summary (best effort)
  - Error and “not available” states per service
- Bottom section shows compact sessions list; tapping goes to Sessions view.
- Menu entries:
  - 구독 사용량 (Usage)
  - 클로드 세션 리스트 (Sessions)
  - Existing menu items

## Error Handling
- Docker missing or run failure → per-profile error banner, preserve last cached snapshot.
- Missing service credentials → mark as “not available” but keep other services visible.
- Partial export failure → profile still saved with available services, surface warning.

## One-Click Profile Switch (Experimental)
- Copies linked profile credentials into active locations:
  - `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`
- Optional Keychain update (best effort).
- No reliability guarantees; minimal manual testing only.

## Security & Storage
- Credentials saved as plaintext JSON with 0600 file permissions.
- No network calls outside the Docker-based usage fetch.

## Non-Functional Requirements
- Usage fetch per profile in <3s on success.
- UI remains responsive while fetching (async).
- Caching avoids repeated Docker runs.
