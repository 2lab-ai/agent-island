# cauth

`cauth` is a standalone Rust CLI for Claude auth profile save/switch/refresh.
Running `cauth` with no arguments prints full profile/account inventory.

## Build and run

```bash
cd /Users/icedac/2lab.ai/agent-island/cauth
cargo run -- help
```

From repository root:

```bash
cd /Users/icedac/2lab.ai/agent-island
make install
cauth help
```

## Commands

- `cauth save <profile>`
  - Saves current Claude auth (`~/.claude/.credentials.json`, keychain fallback) into:
    - `~/.agent-island/accounts/<account-id>/.claude/.credentials.json`
  - Updates `~/.agent-island/accounts.json` profile mapping.

- `cauth switch <profile>`
  - Loads stored profile credentials into active Claude auth:
    - `~/.claude/.credentials.json`
    - macOS keychain service: `Claude Code-credentials`

- `cauth refresh`
  - Refreshes all saved Claude profiles using refresh tokens.
  - Prints per-profile summary:
    - profile name
    - email
    - plan
    - `5h` usage
    - `7d` usage
    - key remaining duration

## Account ID policy

Claude account IDs are email-based when possible:

- personal: `acct_claude_<email-slug>`
- team: `acct_claude_team_<email-slug>`

`<email-slug>` is lowercase and replaces non-alphanumeric chars with `_`.

If email is unavailable, fallback is refresh-token fingerprint hash.

## Refresh safety

- Credential writes are atomic (tempfile + rename).
- Refresh lock key is derived from refresh-token fingerprint.
- Legacy duplicate accounts sharing a refresh token are deduped:
  - token is refreshed once
  - resulting credential is written to all matching account paths

## Test

```bash
cd /Users/icedac/2lab.ai/agent-island/cauth
cargo test
```

## Optional env overrides

- `CLAUDE_CODE_TOKEN_URL`
- `CLAUDE_CODE_USAGE_URL`
- `CAUTH_SECURITY_BIN`

These are primarily for testing and controlled environments.
- `cauth list` (or just `cauth`)
  - Prints:
    - all profiles and linked Claude account state
    - all accounts and link/file/status summary
