# Agent Island Background OAuth Breakage Analysis (As-Is)

Date: 2026-02-12  
Status: Incident analysis + current behavior documentation

## 1) Scope

이 문서는 Agent Island의 백그라운드 Usage refresh 동작이 어떤 경로로 Claude OAuth를 깨먹는지 현재 상태(as-is)를 기록한다.

근거 소스:

- Code:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Resources/UsageScripts/check-usage.js`
- Runtime log:
  - `/Users/icedac/.agent-island/logs/usage-refresh.log`

## 2) Background Refresh가 실제로 도는 방식

### 2.1 트리거

1. `startBackgroundRefreshIfNeeded()`가 호출되면 로딩 직후 `refreshAll()` 실행  
   - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift:95`
2. 이후 10분 주기 타이머(`autoRefreshIntervalSeconds = 10 * 60`)로 `refreshAllIfIdle()` 실행  
   - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift:49`
   - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift:130`

### 2.2 실행 순서

각 refresh task에서:

1. current credential 먼저 조회: `fetchCurrentSnapshot(credentials:)`  
   - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift:179`
2. 그 다음 저장된 profile들을 순회하며 `fetchSnapshot(for:)` 실행  
   - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/UI/Views/UsageDashboardView.swift:196`

즉, 한 번의 백그라운드 refresh는 `current + 모든 profile`을 연속으로 돈다.

### 2.3 current/profile fetch 내부 동작

`UsageFetcher`에서 current/profile 모두:

1. lock 획득
2. temp-home(`~/.agent-island/tmp-homes/<uuid>`) 생성
3. Docker에서 `check-usage.js --json` 실행
4. 종료 후 temp-home credential을 원래 경로로 동기화

관련 코드:

- current path: `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:307`
- profile path: `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:249`
- sync entry: `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:902`

## 3) OAuth를 깨먹는 현재 분기

## 3.1 Partial-success 문제 (Claude auth 실패인데 전체 run은 success)

`check-usage.js`는 Claude fetch가 실패해도(`invalid_grant`, `revoke`) JSON 결과를 생성해 정상 종료(0)할 수 있다.

- Claude refresh 실패 후 `null` 반환:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Resources/UsageScripts/check-usage.js:244`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Resources/UsageScripts/check-usage.js:495`
- 그래도 `main()`은 JSON 출력 후 return:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Resources/UsageScripts/check-usage.js:1827`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Resources/UsageScripts/check-usage.js:1867`

결과적으로 `UsageFetcher`는 `reason = "success"` 분기로 동기화를 진행한다.

## 3.2 Stale-guard가 validity가 아니라 expiresAt만 본다

동기화 판단은 `tokenMaterialChanged` + `expiresAt` 비교 기반이며, 토큰이 revoked인지 여부는 보지 않는다.

- `token_changed_but_source_much_older_on_success`이면 skip:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:1060`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:1086`

그래서 destination이 더 최신 expiry라는 이유로, 이미 revoke된 destination token이 유지될 수 있다.

## 3.3 핵심 사고: temp-home에서 회전 성공 후 커밋 전에 중단

이게 2026-02-12 현재 장애의 직접 원인이다.

동작:

1. Docker 내부 temp-home에서 refresh 성공 -> 새 access/refresh 발급
2. 하지만 `persistUpdatedCredentials(...)` 전 단계에서 프로세스/작업이 중단
3. 활성 저장소(`~/.claude/.credentials.json`, osxkeychain)는 구토큰 그대로 남음
4. 서버 측에서 구토큰 revoke 상태가 되면 active store 전체가 403으로 붕괴

즉, refresh 결과가 temp-home에만 있고 commit이 안 되면 OAuth split-brain이 발생한다.

## 3.4 lock 대기 무기한으로 체감 "멈춤"

process lock은 `flock(LOCK_EX)`로 timeout 없이 대기한다.

- lock 획득 경로:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:793`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:876`

이전 refresh가 release 없이 멈추면 다음 refresh는 `refresh_process_lock_wait`에서 정지한 것처럼 보인다.

## 4) 2026-02-12 Incident Timeline (UTC)

## 4.1 03:50:25Z

`trace_id=9684ba94-88ff-41d9-a23b-a14e7643da12`에서 토큰 회전 성공:

- pre: `at_fp=3f34...`, `rt_fp=b2f9...`
- next: `at_fp=5bce...`, `rt_fp=82f7...`
- active 경로(`~/.claude/.credentials.json`)에 write됨

근거:

- `/Users/icedac/.agent-island/logs/usage-refresh.log:6126`
- `/Users/icedac/.agent-island/logs/usage-refresh.log:6128`

## 4.2 07:43:22Z

`trace_id=af7f04c2-e159-4f3c-a1e8-1c7f2bf4331c`에서 stale-guard skip 발생:

- source: `3f34.../b2f9...` (older)
- destination: `5bce.../82f7...` (newer)
- decision: `token_changed_but_source_much_older_on_success`

근거:

- `/Users/icedac/.agent-island/logs/usage-refresh.log:7553`

## 4.3 07:52:11Z (장애 시점)

`trace_id=58a4ba77-dd7c-4134-802b-6c2d83ff2f0d` current refresh 시작:

- file/keychain 모두 `5bce.../82f7...`로 시작
- 그 직후 다른 trace가 `refresh_process_lock_wait`에 들어갔고, 장애 분석 시점 캡처에서는 이 trace의 `refresh_cycle_completed`가 관측되지 않음

근거:

- `/Users/icedac/.agent-island/logs/usage-refresh.log:7624`
- `/Users/icedac/.agent-island/logs/usage-refresh.log:7626`

## 4.4 08:06:17Z (후속 복구 런 관측)

후속 current refresh(`trace_id=f3ff205f-0d6b-4e6a-a9b8-a534755afe9f`)에서는 이미 회수된 신규 fingerprint(`ce33.../7d0e...`)로 정상 완료가 관측된다.

근거:

- `/Users/icedac/.agent-island/logs/usage-refresh.log:7631`
- `/Users/icedac/.agent-island/logs/usage-refresh.log:7639`

## 4.5 중단 이후 실제 상태

중단된 temp-home에 새 토큰이 남아 있었음:

- temp-home credential fingerprint: `ce33.../7d0e...`
- 해당 access token으로 usage API 직접 호출 시 `HTTP 200`
- 반면 active file/keychain의 `5bce...` 토큰은 `HTTP 403 revoked`

결론: refresh는 성공했지만 commit 단계가 실패/중단되어 active store가 구토큰에 고착됐다.

## 5) "지금" OAuth가 깨지는 메커니즘 요약

1. 백그라운드 refresh가 current + profiles를 주기적으로 돈다.
2. 일부 경로에서 token refresh 성공 결과가 temp-home에만 생길 수 있다.
3. 해당 run이 commit 전에 끊기면 active 저장소는 구토큰 유지.
4. 서버 revoke가 발생하면 active file/keychain이 동시에 403.
5. 다음 refresh는 lock wait 또는 stale-guard skip으로 즉시 자가 복구되지 못할 수 있다.

## 6) 현재 적용된 최소 완화(2026-02-12)

현재 코드에는 incomplete current cycle 복구가 추가되어, 다음 run 시작 전에 최신 미완료 temp-home 토큰을 active store로 회수한다.

- recovery entry:
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:315`
  - `/Users/icedac/2lab.ai/agent-island/ClaudeIsland/Services/Usage/UsageFetcher.swift:365`

이 완화는 "중단 후 미커밋 토큰 손실"을 줄이지만, 다음 항목은 여전히 구조적 리스크다.

- Claude auth 실패를 전체 success로 처리하는 semantics
- validity 미반영 stale-guard
- lock wait timeout 부재
