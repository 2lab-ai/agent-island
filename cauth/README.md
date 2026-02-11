# cauth

`cauth` is a standalone macOS CLI for Claude auth profile save/switch/refresh.

## Commands

```bash
cd /Users/icedac/2lab.ai/agent-island/cauth
swift run cauth help
```

- `cauth save <profile>`
  - Saves current Claude auth (`~/.claude/.credentials.json`, keychain fallback) into:
    - `~/.agent-island/accounts/<account-id>/.claude/.credentials.json`
  - Updates `~/.agent-island/accounts.json` profile mapping.

- `cauth switch <profile>`
  - Loads stored profile credentials into active Claude auth:
    - `~/.claude/.credentials.json`
    - macOS keychain service: `Claude Code-credentials`

- `cauth refresh`
  - Refreshes all Claude profiles using refresh token.
  - Prints per-profile summary:
    - profile name
    - email (if present in credential payload)
    - plan
    - 5h / 7d usage
    - key remaining time

## Account ID policy

Claude account IDs are email-based when possible:

- personal: `acct_claude_<email-slug>`
- team: `acct_claude_team_<email-slug>`

`<email-slug>` replaces non-alphanumeric chars with `_` and lowercases.

If email is unavailable, fallback is refresh-token fingerprint hash.

## Refresh safety

- Refresh writes are atomic (`Data.write(..., .atomic)`).
- Refresh lock key is derived from refresh token fingerprint.
- Legacy duplicate accounts sharing one refresh token are deduplicated:
  - token is refreshed once
  - resulting credential is written back to all matching accounts

## Test

```bash
cd /Users/icedac/2lab.ai/agent-island/cauth
swift test
```

## Optional env overrides

- `CLAUDE_CODE_TOKEN_URL`
- `CLAUDE_CODE_USAGE_URL`
- `CAUTH_SECURITY_BIN`

These are primarily for testing and controlled environments.
