# OAuth Resilience Spec (Agent Island)

Date: 2026-02-12
Status: Draft for implementation (this session)
Owner: Agent Island

## 1. Problem Statement

현재 Claude OAuth credential이 다음 두 저장소에 분산되어 있다.

- File: `~/.claude/.credentials.json`
- Keychain: service `Claude Code-credentials`

기존 구현은 read/write 경로가 일관되지 않아 다음 split-brain이 발생했다.

- file token은 정상인데 keychain token은 revoked 상태로 잔존
- 일부 경로에서 keychain이 file보다 우선되어 정상 file을 무시
- refresh 이후 `unchanged` 분기에서 keychain sync가 생략되어 drift가 장기 유지

## 2. Goals

1. OAuth token material(access/refresh/expiresAt)은 단일 canonical source로 유지한다.
2. current credential refresh 이후 keychain은 항상 canonical state로 수렴한다.
3. read 경로에서 revoked keychain이 정상 file보다 우선되지 않게 한다.
4. profile/current/switch/save 경로에서 동일한 규칙을 강제한다.

## 3. Non-Goals

- 외부 CLI(Claude CLI, cauth)의 내부 동작을 이 스펙에서 직접 변경하지 않는다.
- 네트워크 refresh 프로토콜 자체를 바꾸지 않는다.

## 4. Canonical Model

### 4.1 Source of Truth

- **Canonical token material store = `~/.claude/.credentials.json`**
- Keychain은 mirror store로 취급한다.

Rationale:
- Agent Island runtime은 refresh 결과를 file 기반으로 관리한다.
- Docker refresh 경로는 keychain에 직접 쓰지 않는다.
- keychain stale이 생겨도 file이 최신이면 시스템이 계속 동작해야 한다.

### 4.2 Token Material vs Metadata

- Token material:
  - `claudeAiOauth.accessToken`
  - `claudeAiOauth.refreshToken`
  - `claudeAiOauth.expiresAt` (및 동치 필드)
- Metadata:
  - `email`, `subscriptionType`, `rateLimitTier`, `isTeam`, `account`, `organization`

Rule:
- token material은 canonical file 우선
- metadata는 fallback 소스에서 병합 가능

## 5. State Machine

State per source:
- `Missing`
- `Usable` (access token present)
- `Unusable` (JSON parse 실패 또는 access token 누락)

Resolution:
1. file == Usable: file token material 사용 (keychain은 metadata fallback only)
2. file != Usable && keychain == Usable: keychain token material 사용
3. 둘 다 unusable/missing: available raw 중 best-effort 반환, 없으면 nil

## 6. Required Write/Sync Behavior

### 6.1 Active Claude Sync Contract

`syncActiveClaudeCredentials(data, activeHomeDir)` must:
1. build merged JSON (incoming token material primary, fallback metadata allowed)
2. write keychain (`Claude Code-credentials`)
3. write `~/.claude/.credentials.json`
4. on file write failure: rollback keychain to previous value

### 6.2 Refresh Persistence Contract

When syncing refreshed credentials from temp home:

- If target is active current Claude path (`~/.claude/.credentials.json`):
  - **MUST call active sync even when source == destination (unchanged)**
  - i.e. unchanged file is not a reason to skip keychain convergence
- If target is non-active account file:
  - existing stale-guard decision logic applies

## 7. Read Algorithm (Normative)

For `loadCurrentCredentials().claude`:

1. Read file data from `~/.claude/.credentials.json`
2. Read keychain raw from `Claude Code-credentials`
3. If file is usable:
   - return merged(file primary, keychain metadata fallback)
4. Else if keychain is usable:
   - return merged(keychain primary, file metadata fallback)
5. Else:
   - return file if present else keychain if present else nil

## 8. Invariants

I1. Any successful current refresh run eventually converges keychain to canonical file token material.

I2. A stale/revoked keychain must not override a usable canonical file token material on read.

I3. Profile credential sync must never regress to an older token material on success path.

I4. Sync decisions must be deterministic and loggable (`decision`, `reason`, fingerprints).

## 9. Observability

Required logs:
- `refresh_cycle_started`
- `credential_sync_skipped` / `credential_sync_written`
- `credential_sync_active_claude_synced`
- `credential_sync_active_claude_failed`

All should include:
- trace id
- source/destination path
- refresh/access fingerprints where available

## 10. Acceptance Tests

T1. file usable + keychain revoked/mismatch -> current read returns file token material.

T2. current refresh where source==destination -> active sync still called once.

T3. profile refresh success with stale source token -> destination newer token preserved (existing guard).

T4. active sync failure path logs failure and surfaces error (no silent corruption).

## 11. Implementation Mapping

Primary files:
- `ClaudeIsland/Services/Usage/CredentialExporter.swift`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift`
- `scripts/UsageFetcherTests.swift`

Changes:
- enforce canonical-file read policy in `CredentialExporter`
- enforce active Claude sync on unchanged/write paths in `UsageFetcher.persistUpdatedCredentials`
- add regression test for unchanged path convergence

