# Agent Island - Mac App Store Deployment Plan

## Overview

Rename "Claude Island" → "Agent Island" and prepare for Mac App Store distribution.

**Current state**: Direct distribution via DMG + Sparkle auto-updates, Developer ID signed
**Target state**: Mac App Store distribution + existing DMG channel maintained

---

## Phase 1: App Name Change

### 1.1 Display Name (user-facing)

| File | Change |
|------|--------|
| `ClaudeIsland/Info.plist` | CFBundleName, CFBundleDisplayName → "Agent Island" |
| `project.pbxproj` | PRODUCT_NAME → "Agent Island" (2 locations) |
| `ClaudeIsland.xcscheme` | BuildableName → "Agent Island.app" (3 locations) |
| `Makefile` | APP_NAME → "Agent Island.app", killall target |
| `scripts/build.sh` | Echo messages, export path |
| `scripts/create-release.sh` | DMG volname, icon name, GitHub release notes |
| `README.md` | Title, description text |

### 1.2 Bundle Identifier

| File | Change |
|------|--------|
| `project.pbxproj` | `com.celestial.ClaudeIsland` → `ai.2lab.AgentIsalnd` (2 locations) |
| `AppDelegate.swift:185` | Fallback bundle ID |

### 1.3 File System Paths (user-visible)

| File | Change |
|------|--------|
| `HookSocketServer.swift:110` | `/tmp/claude-island.sock` → `/tmp/agent-island.sock` |
| `claude-island-state.py:12` | Socket path → `/tmp/agent-island.sock` |
| `HookInstaller.swift` | Script name `claude-island-state.py` → `agent-island-state.py` |
| `claude-island-state.py` (filename) | Rename to `agent-island-state.py` |
| `AccountStore.swift:26` | `.claude-island` → `.agent-island` |
| `UsageFetcher.swift` | `.claude-island/tmp-homes`, `.claude-island-scripts` → `.agent-island/*` |
| `ProfileSwitcher.swift:58` | `.claude-island/accounts` → `.agent-island/accounts` |
| `ClaudeCodeTokenStore.swift` | `.claude-island` paths → `.agent-island` |
| `UsageIdentityStore.swift` | `.claude-island` paths → `.agent-island` |

### 1.4 Internal Names (keep as-is)

These do NOT need renaming (not user-visible, renaming carries risk):
- Swift struct names (`ClaudeIslandApp`, etc.)
- Source file names and directory structure (`ClaudeIsland/`)
- Xcode project name (`ClaudeIsland.xcodeproj`)
- File header comments (`// ClaudeIsland`)
- Xcode scheme internal name (`ClaudeIsland`)

---

## Phase 2: Mac App Store Preparation

### 2.1 Sandbox Assessment

**Critical issue**: The app performs system-level operations that conflict with App Sandbox:

| Operation | Current Implementation | Sandbox Impact |
|-----------|----------------------|----------------|
| Hook installation | Writes to `~/.claude/hooks/` | Blocked without entitlement |
| Unix socket | `/tmp/agent-island.sock` | Blocked without entitlement |
| Process monitoring | `NSWorkspace.runningApplications` | Allowed |
| File watching | `~/.claude/projects/` | Blocked without entitlement |
| Shell execution | `Process()` to run commands | Limited |
| Python hooks | Runs Python scripts via hooks | Blocked |

### 2.2 Sandbox Strategy: Temporary Exceptions

For Mac App Store, enable sandbox with these entitlements:

```xml
<!-- App Sandbox (REQUIRED for Mac App Store) -->
<key>com.apple.security.app-sandbox</key>
<true/>

<!-- Network (for socket communication) -->
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>

<!-- File access to Claude config directory -->
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array>
    <string>/Library/Application Support/</string>
    <string>/.claude/</string>
    <string>/.agent-island/</string>
</array>

<!-- Temp directory access for Unix socket -->
<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key>
<array>
    <string>/tmp/agent-island.sock</string>
</array>
```

**Risk**: Apple may reject temporary exception entitlements. If rejected:
- Move socket to `~/Library/Application Support/AgentIsland/`
- Use XPC or App Groups for IPC instead of Unix socket
- Request user to manually install hooks (with security-scoped bookmarks)

### 2.3 Remove Sparkle for App Store Build

App Store handles updates natively. Sparkle must be removed for the App Store target:

1. Add `#if !APPSTORE` conditional compilation around Sparkle imports/usage
2. Add `APPSTORE` Swift compilation flag to App Store build configuration
3. Remove Sparkle-related Info.plist keys for App Store builds

### 2.4 App Store Connect Setup (Manual Steps)

1. Log in to [App Store Connect](https://appstoreconnect.apple.com)
2. Create new app:
   - Platform: macOS
   - Name: "Agent Island"
   - Bundle ID: `ai.2lab.AgentIsalnd`
   - SKU: `agent-island`
   - Primary Language: English
3. Set category: Developer Tools
4. Prepare metadata:
   - Screenshots (1280x800 or 1440x900)
   - Description, keywords, support URL
   - Privacy policy URL
   - Age rating

### 2.5 Build Configuration

Add App Store build configuration to pbxproj:

| Setting | Developer ID (existing) | App Store (new) |
|---------|------------------------|-----------------|
| Code Signing | Developer ID Application | Apple Distribution |
| Provisioning | Automatic | Mac App Store |
| Sandbox | OFF | ON |
| Sparkle | Included | Excluded |
| Export Method | developer-id | app-store |
| Swift Flag | - | APPSTORE |

---

## Phase 3: Build & Upload Scripts

### 3.1 `scripts/build-appstore.sh`

New script for App Store builds:
1. Archive with App Store signing identity
2. Export with `app-store` method
3. Validate with `xcrun altool --validate-app`
4. Upload with `xcrun altool --upload-app` or Transporter

### 3.2 ExportOptions for App Store

```xml
<key>method</key>
<string>app-store</string>
<key>destination</key>
<string>upload</string>
<key>signingStyle</key>
<string>automatic</string>
```

---

## Phase 4: Data Migration

When users upgrade from "Claude Island" to "Agent Island":

1. On first launch, check for `~/.claude-island/` directory
2. If found, copy contents to `~/.agent-island/`
3. Check for old socket path `/tmp/claude-island.sock`
4. Install new hook scripts (replacing old `claude-island-state.py`)

---

## Execution Order

1. **Name change** (Phase 1) - all file edits
2. **Sandbox entitlements** (Phase 2.2) - create App Store entitlements file
3. **Sparkle conditional** (Phase 2.3) - add APPSTORE compile flag
4. **Build scripts** (Phase 3) - create build-appstore.sh
5. **Data migration** (Phase 4) - add migration code
6. **Build verification** - xcodebuild succeeds
7. **Manual**: App Store Connect setup (Phase 2.4)
8. **Manual**: Upload and submit for review

---

## Files Changed Summary

### Modified
- `ClaudeIsland/Info.plist`
- `ClaudeIsland.xcodeproj/project.pbxproj`
- `ClaudeIsland.xcodeproj/xcshareddata/xcschemes/ClaudeIsland.xcscheme`
- `Makefile`
- `scripts/build.sh`
- `scripts/create-release.sh`
- `scripts/generate-keys.sh`
- `README.md`
- `ClaudeIsland/App/AppDelegate.swift`
- `ClaudeIsland/Services/Hooks/HookInstaller.swift`
- `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- `ClaudeIsland/Resources/claude-island-state.py` (renamed)
- `ClaudeIsland/Services/Usage/AccountStore.swift`
- `ClaudeIsland/Services/Usage/UsageFetcher.swift`
- `ClaudeIsland/Services/Usage/ProfileSwitcher.swift`
- `ClaudeIsland/Services/Usage/ClaudeCodeTokenStore.swift`
- `ClaudeIsland/Services/Usage/UsageIdentityStore.swift`
- `ClaudeIsland/Resources/ClaudeIsland.entitlements`

### New
- `docs/deploy-macos-store.md` (this file)
- `scripts/build-appstore.sh`
- `ClaudeIsland/Resources/AgentIsland-AppStore.entitlements`
