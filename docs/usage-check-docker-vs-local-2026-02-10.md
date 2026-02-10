# Usage Check: Docker vs Local Execution (2026-02-10)

## Context

질문:
- Claude 토큰 사용량 체크/리프레시가 지금 Docker 안에서만 실행되는지
- Docker가 필수인지, 로컬 환경변수 기반 실행으로 대체 가능한지

결론 요약:
- 현재 앱 구현은 **기본적으로 Docker 경로를 사용**한다.
- 기능적으로는 **Docker가 절대 필수는 아님**. 로컬 Node 실행으로도 usage 체크/refresh 동작 가능.
- 다만 로컬(macOS) 실행은 Keychain 접근 부작용이 있어, 현재는 Docker 기본 전략이 안전하다.

---

## Current Implementation (Code Evidence)

`UsageFetcher`가 usage 체크를 `fetchUsageFromDocker(...)`로 호출:

- `ClaudeIsland/Services/Usage/UsageFetcher.swift:118`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:174`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:244`

실제 실행은 `docker run`:

- `ClaudeIsland/Services/Usage/UsageFetcher.swift:495`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:500`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:506`

벤더 스크립트 주석도 Docker 실행 의도를 명시:

- `ClaudeIsland/Resources/UsageScripts/check-usage.js:5`

---

## Experiment Design

실험 목적:
- 동일한 credential 상태에서 로컬 Node 실행과 Docker 실행이 모두 refresh를 수행하는지 확인
- 로컬 실행 시 macOS Keychain 관련 부작용 확인

공통 조건:
- 만료된 Claude access token + 유효한 refresh token을 가진 임시 `.claude/.credentials.json`
- mock OAuth token endpoint (`/token`)를 로컬에서 구동
- `CLAUDE_CODE_TOKEN_URL`을 mock endpoint로 설정

실험 A (Local):
- `node ClaudeIsland/Resources/UsageScripts/check-usage.js --json`
- `HOME`을 임시 경로로 지정

실험 B (Docker):
- `docker run --rm --user node ... node:20-alpine node /home/node/.agent-island-scripts/check-usage.js --json`
- 동일 mock endpoint 및 동일 만료 credential 사용

---

## Findings

### 1) Local execution also refreshes token successfully

로컬 실행에서:
- refresh 요청이 수행됨
- 임시 HOME 내 `.claude/.credentials.json`이 새 access/refresh/expiresAt으로 갱신됨

즉, refresh 자체는 Docker 전용 기능이 아니다.

### 2) Local macOS execution triggers Keychain write path

스크립트는 darwin에서 Keychain 저장을 시도:

- `ClaudeIsland/Resources/UsageScripts/check-usage.js:88`
- `ClaudeIsland/Resources/UsageScripts/check-usage.js:105`
- `ClaudeIsland/Resources/UsageScripts/check-usage.js:306`

이 때문에 다음 부작용이 발생 가능:
- Keychain UI 팝업
- 사용자 취소 시 오류 로그
- 시스템 Keychain 상태에 따른 비결정적 동작

중요:
- Keychain 저장 실패가 있어도 파일 credential 갱신(refresh 결과)은 진행될 수 있다.

### 3) Docker execution refreshes token without macOS Keychain popup

Docker 컨테이너는 Linux 환경이므로 `process.platform !== "darwin"` 경로를 타서 Keychain 호출이 없다.
결과적으로:
- refresh 동작 자체는 동일하게 수행
- host macOS Keychain 팝업/권한 이슈가 제거됨

---

## Why Keeping Docker Now Is Reasonable

현재 결정을 Docker 유지로 두는 이유:

1. 실행 환경 일관성
- host macOS 설정/권한 변화 영향을 줄임

2. 부작용 최소화
- Keychain 팝업/권한 오류/사용자 인터랙션 이슈 회피

3. 격리 보장
- 임시 HOME + 컨테이너 실행으로 usage 체크 중 host 상태 오염 최소화

4. 미래 호환성 관점
- Claude CLI의 macOS 인증/Keychain 동작이 바뀌어도 Linux 컨테이너 경로는 상대적으로 안정적일 가능성이 높음

---

## How To Remove Docker Dependency Later (Detailed Plan)

아래는 “나중에 Docker 의존을 빼는” 현실적인 단계별 계획이다.

## Phase 0: 목표 정의

목표:
- Docker 없이 usage 체크/refresh 가능
- Keychain 팝업/권한 문제 없이 비대화형으로 안정 동작
- 기존 Docker 경로는 fallback으로 유지(초기)

성공 기준:
- Local runner로 profile/current usage fetch 성공
- token refresh 후 credential sync 동작 유지
- 기존 UI/캐시/에러 처리 회귀 없음

## Phase 1: Runner 추상화 도입

`UsageFetcher`의 실행기를 인터페이스로 분리:

- 예시: `UsageCheckRunner` (run(homeURL, scriptPath, context/env) -> Data)
- 구현체:
  - `DockerUsageCheckRunner` (현행 로직)
  - `LocalNodeUsageCheckRunner` (신규)

필요 변경 지점:
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:244`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift:484`

핵심:
- fetcher는 “무엇을 실행할지” 몰라도 되고, 실행 전략만 주입받는다.

## Phase 2: LocalNode runner 구현

구현 원칙:
- `node check-usage.js --json` 직접 실행
- `HOME`은 지금처럼 임시 home 디렉터리 사용
- `CLAUDE_CODE_TOKEN_URL`, `CLAUDE_CODE_OAUTH_CLIENT_ID` 등 필요한 env 전달

실행 전 검증:
- `node` 바이너리 존재 여부 확인
- 없으면 명확한 에러 + Docker fallback

## Phase 3: Keychain side-effect 차단 (핵심)

Docker 제거의 실제 난점은 Keychain 호출이다.

권장안 A (가장 명확):
- 벤더 `check-usage.js`에 opt-out env 추가:
  - 예: `CLAUDE_DASHBOARD_DISABLE_KEYCHAIN=1`
- darwin에서도 해당 env가 true면 `saveClaudeCredentialsToKeychain` 스킵

권장안 B (임시 우회):
- Local runner에서 `PATH`를 제한해 `security` 명령 호출 불가 상태로 실행
- 이 방식도 동작은 가능하지만, 로그에 ENOENT가 남아 덜 깔끔함

권장:
- 장기적으로는 A를 사용하고, upstream 반영 가능 여부 확인

## Phase 4: 설정 및 rollout

런타임 선택 정책:
- 기본: Docker
- 옵션: Local (실험 기능 또는 고급 설정)
- 자동 fallback:
  - Local 실패 -> Docker 재시도
  - Docker 실패 -> 캐시/에러 상태 노출

관측성:
- 어느 runner를 사용했는지 로그/telemetry에 기록
- refresh 성공/실패 원인 분리 기록

## Phase 5: 테스트 전략

필수 테스트:
1. Local runner 기본 성공 케이스
2. Local runner + refresh 후 credential 파일 갱신 검증
3. Local runner + keychain disable env 케이스
4. node 미설치 시 Docker fallback
5. Docker runner 기존 회귀 테스트

권장:
- mock OAuth 서버 기반 통합 테스트를 CI에서 재현 가능하게 스크립트화

---

## Decision (2026-02-10)

현시점 운영 결정:
- **Docker 유지**

사유:
- 이미 안정 동작 중
- macOS Keychain 부작용 리스크가 낮아짐
- 추후 필요 시 runner 추상화 + keychain opt-out로 안전하게 Local 전환 가능

