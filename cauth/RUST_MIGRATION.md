# cauth Rust Migration Contract

## Goal

Replace Swift `cauth` with Rust implementation while preserving behavior and data compatibility.

## Command parity

- `cauth save <profile-name>`
- `cauth switch <profile-name>`
- `cauth refresh`
- `cauth help`

Argument and usage error behavior:

- unknown command -> exit code `2`
- wrong argument count -> exit code `2`
- runtime failure -> exit code `1`

## Data model parity

Paths remain unchanged:

- active credential: `~/.claude/.credentials.json`
- account store root: `~/.agent-island`
- accounts file: `~/.agent-island/accounts.json`
- account credential: `~/.agent-island/accounts/<account-id>/.claude/.credentials.json`

`accounts.json` compatibility:

- same `accounts` and `profiles` shape
- same `camelCase` fields
- profile upsert preserves `codexAccountId` and `geminiAccountId`

## Account ID policy parity

- personal: `acct_claude_<email-slug>`
- team: `acct_claude_team_<email-slug>`
- fallback: refresh-token fingerprint hash

`<email-slug>`:

- lowercase
- non-alphanumeric converted to `_`
- repeated separators collapsed

## Refresh behavior parity

- OAuth refresh endpoint and scope behavior preserved
- refresh updates:
  - stored profile credentials
  - active `~/.claude/.credentials.json` for active account
  - macOS keychain (`Claude Code-credentials`) for active account
- per-refresh-token lock for race safety
- atomic credential writes (tempfile + rename)
- duplicate accounts sharing refresh token refresh once and fan out result

## Output parity

`cauth refresh` prints one line per profile:

- profile name
- email
- plan
- 5h usage
- 7d usage
- `(key)` remaining duration

Missing values are rendered as `--` and should not panic.
