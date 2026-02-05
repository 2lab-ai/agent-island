# Usage Profiles & Subscription Dashboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a default Usage dashboard with profile-based Claude/Codex/Gemini usage, backed by locally stored account credentials and Docker-based usage fetching.

**Architecture:** Persist accounts/profiles in `~/.claude-island/accounts.json`, export credentials into account roots, assemble a temporary HOME per profile, then run the vendored `check-usage.js --json` inside Docker and parse results for the UI.

**Tech Stack:** Swift/SwiftUI, Foundation, Docker, Node.js (via `node:20-alpine`)

---

### Task 1: Add Usage Models + JSON Parsing

**Files:**
- Create: `ClaudeIsland/Models/UsageModels.swift`
- Create: `scripts/UsageModelsTests.swift`

**Step 1: Write the failing test**
```swift
// scripts/UsageModelsTests.swift
import Foundation

@main
enum UsageModelsTests {
    static func main() {
        let json = """
        {
          "claude": { "name": "Claude", "available": true, "error": false,
            "fiveHourPercent": 12, "sevenDayPercent": 34,
            "fiveHourReset": "2026-02-05T10:00:00.000Z",
            "sevenDayReset": "2026-02-12T10:00:00.000Z"
          },
          "codex": null,
          "gemini": null,
          "zai": null,
          "recommendation": "claude",
          "recommendationReason": "lowest usage"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try! decoder.decode(CheckUsageOutput.self, from: data)
        print("OK")
    }
}
```

**Step 2: Run test to verify it fails**
Run:
```bash
swiftc -o /tmp/usage-models-test ClaudeIsland/Models/UsageModels.swift scripts/UsageModelsTests.swift
```
Expected: FAIL (missing `CheckUsageOutput`).

**Step 3: Write minimal implementation**
```swift
// ClaudeIsland/Models/UsageModels.swift
import Foundation

struct CheckUsageOutput: Decodable {
    let claude: CLIUsageInfo
    let codex: CLIUsageInfo?
    let gemini: CLIUsageInfo?
    let zai: CLIUsageInfo?
    let recommendation: String?
    let recommendationReason: String
}

struct CLIUsageInfo: Decodable {
    let name: String
    let available: Bool
    let error: Bool
    let fiveHourPercent: Int?
    let sevenDayPercent: Int?
    let fiveHourReset: Date?
    let sevenDayReset: Date?
    let model: String?
    let plan: String?
    let buckets: [BucketUsageInfo]?
}

struct BucketUsageInfo: Decodable {
    let modelId: String
    let usedPercent: Int?
    let resetAt: Date?
}
```

**Step 4: Run test to verify it passes**
Run:
```bash
swiftc -o /tmp/usage-models-test ClaudeIsland/Models/UsageModels.swift scripts/UsageModelsTests.swift
```
Expected: PASS (prints `OK`).

**Step 5: Commit**
```bash
git add ClaudeIsland/Models/UsageModels.swift scripts/UsageModelsTests.swift
git commit -m "feat: add usage models and parsing test"
```

---

### Task 2: Account + Profile Store

**Files:**
- Create: `ClaudeIsland/Services/Usage/AccountStore.swift`
- Create: `ClaudeIsland/Services/Usage/ProfileStore.swift`
- Create: `scripts/AccountStoreTests.swift`

**Step 1: Write the failing test**
```swift
// scripts/AccountStoreTests.swift
import Foundation

@main
enum AccountStoreTests {
    static func main() throws {
        let store = AccountStore(rootDir: URL(fileURLWithPath: "/tmp/claude-island-test"))
        let profile = UsageProfile(name: "A", claudeAccountId: "acct1", codexAccountId: nil, geminiAccountId: nil)
        try store.saveProfiles([profile])
        let loaded = try store.loadProfiles()
        assert(loaded.first?.name == "A")
        print("OK")
    }
}
```

**Step 2: Run test to verify it fails**
Run:
```bash
swiftc -o /tmp/account-store-test ClaudeIsland/Services/Usage/AccountStore.swift ClaudeIsland/Services/Usage/ProfileStore.swift scripts/AccountStoreTests.swift
```
Expected: FAIL (missing types).

**Step 3: Write minimal implementation**
Define:
- `UsageProfile` struct
- `AccountStore` with `accounts.json` read/write
- `ProfileStore` or combined store for profiles

**Step 4: Run test to verify it passes**
Run:
```bash
swiftc -o /tmp/account-store-test ClaudeIsland/Services/Usage/AccountStore.swift ClaudeIsland/Services/Usage/ProfileStore.swift scripts/AccountStoreTests.swift
```
Expected: PASS.

**Step 5: Commit**
```bash
git add ClaudeIsland/Services/Usage/AccountStore.swift ClaudeIsland/Services/Usage/ProfileStore.swift scripts/AccountStoreTests.swift
git commit -m "feat: add account and profile stores"
```

---

### Task 3: Credential Exporter

**Files:**
- Create: `ClaudeIsland/Services/Usage/CredentialExporter.swift`

**Step 1: Write the failing test**
Create a simple exporter test that writes sample credential JSON into a temp account root.

**Step 2: Run test to verify it fails**
Run:
```bash
swiftc -o /tmp/cred-export-test ClaudeIsland/Services/Usage/CredentialExporter.swift scripts/CredentialExporterTests.swift
```
Expected: FAIL (missing implementation).

**Step 3: Write minimal implementation**
- Read Claude token from Keychain (`security find-generic-password ...`) or `~/.claude/.credentials.json`
- Read Codex token from `~/.codex/auth.json`
- Read Gemini token from Keychain (`gemini-cli-oauth`) or `~/.gemini/oauth_creds.json`
- Export into account root with 0600 permissions

**Step 4: Run test to verify it passes**
Run:
```bash
swiftc -o /tmp/cred-export-test ClaudeIsland/Services/Usage/CredentialExporter.swift scripts/CredentialExporterTests.swift
```
Expected: PASS.

**Step 5: Commit**
```bash
git add ClaudeIsland/Services/Usage/CredentialExporter.swift scripts/CredentialExporterTests.swift
git commit -m "feat: add credential exporter"
```

---

### Task 4: Docker Usage Fetcher + Cache

**Files:**
- Create: `ClaudeIsland/Services/Usage/UsageFetcher.swift`
- Create: `ClaudeIsland/Services/Usage/UsageCache.swift`
- Add: `ClaudeIsland/Resources/UsageScripts/check-usage.js`

**Step 1: Write the failing test**
- Add a test that feeds a JSON string into a parser helper and asserts output.

**Step 2: Run test to verify it fails**
Run:
```bash
swiftc -o /tmp/usage-fetcher-test ClaudeIsland/Models/UsageModels.swift ClaudeIsland/Services/Usage/UsageFetcher.swift scripts/UsageFetcherTests.swift
```
Expected: FAIL (missing parser helper).

**Step 3: Write minimal implementation**
- Bundle `check-usage.js` as a resource.
- Create a temp HOME folder and copy `.claude/.codex/.gemini` from linked account roots.
- Run Docker: `docker run --rm -v <tempHome>:/home/node -v <scriptPath>:/app/check-usage.js node:20-alpine node /app/check-usage.js --json`
- Parse JSON into `CheckUsageOutput`.
- Cache results for 60s.

**Step 4: Run test to verify it passes**
Run:
```bash
swiftc -o /tmp/usage-fetcher-test ClaudeIsland/Models/UsageModels.swift ClaudeIsland/Services/Usage/UsageFetcher.swift scripts/UsageFetcherTests.swift
```
Expected: PASS.

**Step 5: Commit**
```bash
git add ClaudeIsland/Services/Usage/UsageFetcher.swift ClaudeIsland/Services/Usage/UsageCache.swift ClaudeIsland/Resources/UsageScripts/check-usage.js scripts/UsageFetcherTests.swift
git commit -m "feat: add docker usage fetcher"
```

---

### Task 5: Usage Dashboard UI + Navigation

**Files:**
- Create: `ClaudeIsland/UI/Views/UsageDashboardView.swift`
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`
- Modify: `ClaudeIsland/UI/Views/NotchView.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`
- Modify: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`

**Step 1: Write the failing test**
- Add a simple snapshot-like test harness or manual preview with mocked data (document in plan).

**Step 2: Run test to verify it fails**
- Manual: open preview and confirm missing view.

**Step 3: Write minimal implementation**
- Add `.usage` content type, make it default.
- Add menu entries for Usage and Sessions.
- Add UsageDashboardView with profile list + sessions preview.
- Sessions preview click navigates to sessions list.

**Step 4: Run test to verify it passes**
- Manual: build app and verify navigation flows.

**Step 5: Commit**
```bash
git add ClaudeIsland/UI/Views/UsageDashboardView.swift ClaudeIsland/Core/NotchViewModel.swift ClaudeIsland/UI/Views/NotchView.swift ClaudeIsland/UI/Views/NotchMenuView.swift ClaudeIsland/UI/Views/ClaudeInstancesView.swift
git commit -m "feat: add usage dashboard UI"
```

---

### Task 6: Profile Save + Experimental Switch

**Files:**
- Create: `ClaudeIsland/Services/Usage/ProfileSwitcher.swift`
- Modify: `ClaudeIsland/UI/Views/UsageDashboardView.swift`

**Step 1: Write the failing test**
- Create a test for profile save linking and a manual test checklist for switching.

**Step 2: Run test to verify it fails**
- Manual: attempt save/switch without implementation.

**Step 3: Write minimal implementation**
- Save Profile: export credentials, link to accounts.
- Switch Profile: copy account credentials into `~/.claude`, `~/.codex`, `~/.gemini`.
- Add confirmation dialog; mark as experimental.

**Step 4: Run test to verify it passes**
- Manual: smoke test save and switch flows.

**Step 5: Commit**
```bash
git add ClaudeIsland/Services/Usage/ProfileSwitcher.swift ClaudeIsland/UI/Views/UsageDashboardView.swift
git commit -m "feat: add profile save and switch"
```

---

### Task 7: Verification

**Step 1: Run build**
Run:
```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build
```

**Step 2: Manual smoke checks**
- Usage dashboard opens by default.
- Profiles list loads.
- Sessions preview navigates to sessions list.
- Docker usage fetch works on a profile.
- Profile save creates account roots.

**Step 3: Commit any final adjustments**

