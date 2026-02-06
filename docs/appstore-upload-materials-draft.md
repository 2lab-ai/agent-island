# Agent Island App Store 업로드 자료 초안

이 문서는 App Store Connect 수동 작업 중 2번 항목(스크린샷, 설명, 개인정보 처리방침)을 바로 붙여 넣을 수 있도록 만든 초안이다.

## 0) 기본 값

- App Name: `Agent Island`
- Bundle ID: `ai.2lab.AgentIsalnd`
- Platform: `macOS`
- Category: `Developer Tools`
- Language: `Korean (ko-KR)` 기준 초안

## 1) App Store Connect 메타데이터 초안

### 1.1 Subtitle

```text
Claude Code를 위한 Dynamic Island 알림 허브
```

### 1.2 Promotional Text

```text
터미널을 벗어나지 않고 Claude Code 승인 요청, 세션 상태, 대화 히스토리를 Mac 노치 UI에서 즉시 확인하세요.
```

### 1.3 Keywords

```text
claude,ai,agent,terminal,developer,menubar,notch,workflow,approval,assistant
```

### 1.4 Description

```text
Agent Island는 Claude Code CLI 세션을 위한 macOS 메뉴바 앱입니다.

MacBook 노치에서 확장되는 Dynamic Island 스타일 UI로 세션 상태를 실시간으로 보여주고, 도구 실행 승인 요청을 바로 처리할 수 있습니다. 터미널과 창 사이를 오가는 흐름을 줄여, 코드 작업의 집중도를 높입니다.

핵심 기능
- 노치 기반 실시간 알림 UI
- 복수 Claude Code 세션 모니터링
- 승인/거절 액션을 앱에서 즉시 처리
- Markdown 렌더링 기반 대화 히스토리 확인
- 최초 실행 시 훅 자동 설치

Agent Island는 개발자 워크플로우에 맞춰 빠른 피드백 루프를 제공합니다.
승인 대기, 세션 전환, 대화 확인 같은 반복 행동을 최소화해 실제 구현 시간에 더 집중할 수 있습니다.

분석 및 데이터 처리
- 앱 실행, 세션 시작 같은 익명 사용 이벤트를 수집할 수 있습니다.
- 개인 식별 정보, 대화 본문, 프롬프트 내용은 수집하지 않습니다.
- 자세한 내용은 개인정보 처리방침을 확인하세요.
```

### 1.5 What's New (Version 1.2 예시)

```text
- Agent Island 브랜딩 정리 및 App Store 배포 준비
- 세션 모니터링 안정성 개선
- 노치 알림 동작 및 승인 UX 개선
- 내부 품질/빌드 파이프라인 정비
```

### 1.6 Support URL / Marketing URL / Privacy Policy URL 초안

- Support URL: `https://2lab.ai/support/agent-island`
- Marketing URL: `https://2lab.ai/agent-island`
- Privacy Policy URL: `https://2lab.ai/legal/agent-island-privacy`

## 2) 스크린샷 제작 프롬프트 초안

권장 업로드 세트:
- 1차: `1440x900` 6장
- 보조: `1280x800` 동일 콘셉트 6장

일관성 가이드:
- macOS Sonoma 스타일, 밝은 모드 기준
- 실제 제품명은 항상 `Agent Island`
- 노치 UI와 터미널 문맥이 동시에 보이도록 구성
- 과한 합성 느낌보다 실제 앱 캡처 같은 톤 유지

### Screenshot 1: 제품 한 줄 소개 (Hero)

목표 메시지: "Claude Code 알림이 노치에 바로 뜬다"

```text
Create a realistic macOS screenshot (1440x900) of a MacBook desktop with a subtle wallpaper and terminal window open. Show a notch-centered overlay UI named "Agent Island" expanding from the top notch. The overlay displays "Session Active", "3 tools waiting", and two buttons: "Approve" and "Deny". Keep typography clean, modern, and readable. Add a marketing caption area at bottom-left saying: "Claude Code alerts, right on your notch." Keep the scene natural and product-focused.
```

### Screenshot 2: 승인 플로우 강조

목표 메시지: "승인/거절을 앱에서 즉시 처리"

```text
Generate a realistic product screenshot for a macOS app (1440x900). Focus on the Agent Island notch overlay showing a permission request card with tool name, command preview, and risk label. Include clear primary and secondary actions: "Approve" and "Deny". In the background, show a coding terminal and editor window slightly blurred. Add a clean caption line: "Review and approve tool actions in seconds."
```

### Screenshot 3: 멀티 세션 모니터링

목표 메시지: "여러 Claude 세션을 한 번에 추적"

```text
Create a macOS app marketing screenshot (1440x900) featuring Agent Island session list UI. Show multiple active Claude Code sessions with status pills (Running, Waiting, Completed), elapsed time, and project names. Keep the notch overlay visible at top. The interface should feel native to macOS with smooth rounded panels. Add caption text: "Track every Claude Code session in one place."
```

### Screenshot 4: 대화 히스토리/맥락 확인

목표 메시지: "터미널을 떠나지 않고 맥락 확인"

```text
Produce a realistic desktop screenshot (1440x900) for Agent Island on macOS. Show a side panel with markdown-rendered chat history, including headings, code blocks, and timestamps. Keep the terminal visible behind it to imply ongoing workflow. Use clean spacing and high contrast for readability. Add caption: "Open chat history with full markdown context."
```

### Screenshot 5: 자동 설정(훅 설치) 경험

목표 메시지: "처음 실행 후 바로 사용 가능"

```text
Design a polished macOS screenshot (1440x900) showing Agent Island first-run setup flow. Include a compact onboarding modal with steps: "Detect Claude CLI", "Install Hooks", "Ready". Show success states with checkmarks and one primary button: "Finish Setup". Keep style minimal and native-like. Add caption text: "Auto-setup gets you ready in under a minute."
```

### Screenshot 6: 개인정보/안전성 메시지

목표 메시지: "대화 내용은 수집하지 않음"

```text
Create a trustworthy macOS marketing screenshot (1440x900) for Agent Island privacy settings. Show a settings view with analytics toggles and a clear statement card: "No prompt or conversation content is collected." Keep visuals clean, professional, and developer-centric. Include a small notch preview at top to keep brand continuity. Add caption: "Built for developers, with privacy by default."
```

## 3) 개인정보 처리방침 초안 (게시용 원문)

아래 문안을 웹페이지로 게시 후, 해당 URL을 App Store Connect의 Privacy Policy URL에 입력하면 된다.

```text
Agent Island 개인정보 처리방침

시행일: 2026-02-06

2lab.ai(이하 "회사")는 Agent Island(이하 "앱") 사용자의 개인정보를 중요하게 생각하며, 관련 법령을 준수합니다.
본 방침은 앱에서 어떤 데이터를 수집하고 어떻게 사용하는지 설명합니다.

1. 수집하는 정보
- 앱 버전, 빌드 번호, macOS 버전
- 앱 실행 이벤트, 세션 시작 이벤트
- 앱 안정성 및 사용성 개선을 위한 익명 진단 정보

2. 수집하지 않는 정보
- Claude 대화 본문 및 프롬프트 내용
- 터미널 명령의 민감한 본문
- 개인 식별이 가능한 계정 비밀번호/토큰 원문

3. 정보 이용 목적
- 앱 기능 제공 및 성능 개선
- 오류 진단 및 안정성 확보
- 제품 사용성 분석(익명/집계 기반)

4. 제3자 제공 및 처리위탁
- 앱은 분석 도구(Mixpanel)를 사용할 수 있으며, 익명 이벤트 데이터가 해당 서비스로 전송될 수 있습니다.
- 법령에 근거한 경우를 제외하고, 개인을 식별할 수 있는 정보를 판매하거나 임의 제공하지 않습니다.

5. 보관 및 파기
- 수집된 데이터는 목적 달성에 필요한 기간 동안만 보관하며, 이후 지체 없이 삭제 또는 비식별 처리합니다.

6. 이용자 권리
- 이용자는 데이터 처리 관련 문의 및 삭제 요청을 할 수 있습니다.

7. 문의처
- 이메일: privacy@2lab.ai
- 웹사이트: https://2lab.ai

회사는 본 방침을 변경할 수 있으며, 중요한 변경 시 웹사이트 또는 앱 공지를 통해 안내합니다.
```

## 4) App Store 업로드 전 체크리스트

- [ ] App Store Connect 설명/키워드/홍보문구 반영
- [ ] Privacy Policy URL 게시 및 접근 확인
- [ ] 6장 스크린샷 해상도별 준비(1440x900, 필요 시 1280x800)
- [ ] 스크린샷 내 표기 명칭 `Agent Island` 일관성 확인
- [ ] 번들 ID `ai.2lab.AgentIsalnd`로 앱 레코드 생성 확인
