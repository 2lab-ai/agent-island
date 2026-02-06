import Combine
import Darwin
import Foundation
import SwiftUI

struct UsageAccountIdSet: Sendable, Equatable {
    let claude: String?
    let codex: String?
    let gemini: String?

    static let empty = UsageAccountIdSet(claude: nil, codex: nil, gemini: nil)

    var hasAny: Bool {
        claude != nil || codex != nil || gemini != nil
    }

    func matches(profile: UsageProfile) -> Bool {
        claude == profile.claudeAccountId &&
            codex == profile.codexAccountId &&
            gemini == profile.geminiAccountId
    }
}

@MainActor
final class UsageDashboardViewModel: ObservableObject {
    static let shared = UsageDashboardViewModel()

    @Published var profiles: [UsageProfile] = []
    @Published var currentSnapshot: UsageSnapshot?
    @Published var currentAccountIds: UsageAccountIdSet = .empty
    @Published var liveProfileName: String?
    @Published var snapshotsByProfileName: [String: UsageSnapshot] = [:]
    @Published var claudeCodeTokenStatusByAccountId: [String: ClaudeCodeTokenStatus] = [:]
    @Published var isRefreshing = false
    @Published var isSavingProfile = false
    @Published var switchingProfileName: String?
    @Published var loadErrorMessage: String?
    @Published var lastActionMessage: String?

    private let accountStore: AccountStore
    private let profileStore: ProfileStore
    private let fetcher: UsageFetcher
    private let switcher: ProfileSwitcher
    private let exporter: CredentialExporter
    private let claudeCodeTokenStore = ClaudeCodeTokenStore()

    private var refreshTask: Task<Void, Never>?
    private var autoRefreshCancellable: AnyCancellable?
    private let autoRefreshIntervalSeconds: TimeInterval = 10 * 60
    private var backgroundRefreshStarted = false
    private var lastKnownEmailByAccountId: [String: String] = [:]
    private var lastKnownTierByAccountId: [String: String] = [:]
    private var lastKnownPlanByAccountId: [String: String] = [:]
    private var lastKnownClaudeIsTeamByAccountId: [String: Bool] = [:]
    private var lastKnownCurrentAccountIds: UsageAccountIdSet = .empty
    private let identityStore = UsageIdentityStore()
    private var loadedPersistedIdentities = false

    init(accountStore: AccountStore = AccountStore()) {
        self.accountStore = accountStore
        self.profileStore = ProfileStore(accountStore: accountStore)
        self.fetcher = UsageFetcher(accountStore: accountStore, cache: UsageCache())
        let exporter = CredentialExporter()
        self.exporter = exporter
        self.switcher = ProfileSwitcher(accountStore: accountStore, exporter: exporter)
    }

    private func loadPersistedIdentitiesIfNeeded() async {
        guard !loadedPersistedIdentities else { return }
        loadedPersistedIdentities = true

        do {
            let snapshot = try await identityStore.snapshot()

            for (accountId, identity) in snapshot {
                if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil {
                    lastKnownEmailByAccountId[accountId] = email
                }
                if let tier = identity.tier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil {
                    lastKnownTierByAccountId[accountId] = tier
                }
                if let plan = identity.plan?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil {
                    lastKnownPlanByAccountId[accountId] = plan
                }
                if let isTeam = identity.claudeIsTeam {
                    lastKnownClaudeIsTeamByAccountId[accountId] = isTeam
                }
            }
        } catch {
            // Best-effort: identity cache should never block the dashboard.
            lastActionMessage = error.localizedDescription
        }
    }

    func startBackgroundRefreshIfNeeded() {
        guard !backgroundRefreshStarted else { return }
        backgroundRefreshStarted = true
        Task { [weak self] in
            guard let self else { return }
            await self.loadPersistedIdentitiesIfNeeded()
            await self.reloadClaudeCodeTokenStatuses(silent: true)
            self.load()
            self.startAutoRefresh()
        }
    }

    func load() {
        do {
            loadErrorMessage = nil
            profiles = try profileStore.loadProfiles()
        } catch {
            loadErrorMessage = error.localizedDescription
            profiles = []
        }

        updateLiveProfileName()
        refreshAll()
    }

    func startAutoRefresh() {
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = Timer.publish(every: autoRefreshIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshAllIfIdle()
            }
    }

    func stopAutoRefresh() {
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh(selectedProfileName: String? = nil) {
        let profilesToRefresh: [UsageProfile]
        if let selectedProfileName,
           let profile = profiles.first(where: { $0.name == selectedProfileName }) {
            profilesToRefresh = [profile]
        } else {
            profilesToRefresh = []
        }

        startRefresh(profilesToRefresh: profilesToRefresh)
    }

    func refreshAll() {
        startRefresh(profilesToRefresh: profiles)
    }

    func refreshAllIfIdle() {
        guard !isRefreshing else { return }
        refreshAll()
    }

    private func startRefresh(profilesToRefresh: [UsageProfile]) {
        refreshTask?.cancel()
        isRefreshing = true

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }

            let credentials = exporter.loadCurrentCredentials()
            updateCurrentAccountIds(credentials: credentials)
            updateLiveProfileName()
            let fetchedCurrent = await fetcher.fetchCurrentSnapshot(credentials: credentials)
            let mergedCurrent = snapshotWithRememberedIdentities(fetchedCurrent, accountIds: currentAccountIds)
            rememberIdentities(from: mergedCurrent, accountIds: currentAccountIds)
            currentSnapshot = mergedCurrent

            for profile in profilesToRefresh {
                if Task.isCancelled { break }
                let fetchedSnapshot = await fetcher.fetchSnapshot(for: profile)
                let accountIds = UsageAccountIdSet(
                    claude: profile.claudeAccountId,
                    codex: profile.codexAccountId,
                    gemini: profile.geminiAccountId
                )
                let mergedSnapshot = snapshotWithRememberedIdentities(fetchedSnapshot, accountIds: accountIds)
                rememberIdentities(from: mergedSnapshot, accountIds: accountIds)
                snapshotsByProfileName[profile.name] = mergedSnapshot
            }
        }
    }

    private func updateCurrentAccountIds(credentials: ExportCredentials) {
        let computed = computeAccountIds(credentials: credentials)
        if computed.hasAny {
            lastKnownCurrentAccountIds = computed
            currentAccountIds = computed
        } else if lastKnownCurrentAccountIds.hasAny {
            currentAccountIds = lastKnownCurrentAccountIds
        } else {
            currentAccountIds = computed
        }
    }

    private func computeAccountIds(credentials: ExportCredentials) -> UsageAccountIdSet {
        UsageAccountIdSet(
            claude: credentials.claude.map { UsageCredentialHasher.fingerprint(service: .claude, data: $0).accountId },
            codex: credentials.codex.map { UsageCredentialHasher.fingerprint(service: .codex, data: $0).accountId },
            gemini: credentials.gemini.map { UsageCredentialHasher.fingerprint(service: .gemini, data: $0).accountId }
        )
    }

    private func snapshotWithRememberedIdentities(_ snapshot: UsageSnapshot, accountIds: UsageAccountIdSet) -> UsageSnapshot {
        let rememberedClaudeEmail = accountIds.claude.flatMap { lastKnownEmailByAccountId[$0] }
        let rememberedClaudeTier = accountIds.claude.flatMap { lastKnownTierByAccountId[$0] }
        let rememberedClaudePlan = accountIds.claude.flatMap { lastKnownPlanByAccountId[$0] }
        let rememberedClaudeIsTeam = accountIds.claude.flatMap { lastKnownClaudeIsTeamByAccountId[$0] }
        let rememberedCodexEmail = accountIds.codex.flatMap { lastKnownEmailByAccountId[$0] }
        let rememberedGeminiEmail = accountIds.gemini.flatMap { lastKnownEmailByAccountId[$0] }

        func normalize(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        }

        let mergedIdentities = UsageIdentities(
            claudeEmail: normalize(snapshot.identities.claudeEmail) ?? rememberedClaudeEmail,
            claudeTier: rememberedClaudePlan ?? normalize(snapshot.identities.claudeTier) ?? rememberedClaudeTier,
            claudeIsTeam: snapshot.identities.claudeIsTeam ?? rememberedClaudeIsTeam,
            codexEmail: normalize(snapshot.identities.codexEmail) ?? rememberedCodexEmail,
            geminiEmail: normalize(snapshot.identities.geminiEmail) ?? rememberedGeminiEmail
        )

        return UsageSnapshot(
            profileName: snapshot.profileName,
            output: snapshot.output,
            identities: mergedIdentities,
            tokenRefresh: snapshot.tokenRefresh,
            fetchedAt: snapshot.fetchedAt,
            isStale: snapshot.isStale,
            errorMessage: snapshot.errorMessage
        )
    }

    private func rememberIdentities(from snapshot: UsageSnapshot, accountIds: UsageAccountIdSet) {
        func normalize(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        }

        var updates: [(accountId: String, email: String?, tier: String?, claudeIsTeam: Bool?)] = []

        if let accountId = accountIds.claude {
            let email = normalize(snapshot.identities.claudeEmail)
            let tier = normalize(snapshot.identities.claudeTier)
            let isTeam = snapshot.identities.claudeIsTeam

            if let email { lastKnownEmailByAccountId[accountId] = email }
            if let tier { lastKnownTierByAccountId[accountId] = tier }
            if let isTeam { lastKnownClaudeIsTeamByAccountId[accountId] = isTeam }

            if email != nil || tier != nil || isTeam != nil {
                updates.append((accountId: accountId, email: email, tier: tier, claudeIsTeam: isTeam))
            }
        }

        if let accountId = accountIds.codex {
            let email = normalize(snapshot.identities.codexEmail)
            if let email {
                lastKnownEmailByAccountId[accountId] = email
                updates.append((accountId: accountId, email: email, tier: nil, claudeIsTeam: nil))
            }
        }

        if let accountId = accountIds.gemini {
            let email = normalize(snapshot.identities.geminiEmail)
            if let email {
                lastKnownEmailByAccountId[accountId] = email
                updates.append((accountId: accountId, email: email, tier: nil, claudeIsTeam: nil))
            }
        }

        guard !updates.isEmpty else { return }

        Task { [updates, identityStore] in
            for update in updates {
                do {
                    try await identityStore.update(
                        accountId: update.accountId,
                        email: update.email,
                        tier: update.tier,
                        claudeIsTeam: update.claudeIsTeam
                    )
                } catch {
                    // Best-effort: identity persistence should never block the dashboard.
                }
            }
        }
    }

    private func updateLiveProfileName() {
        guard currentAccountIds.hasAny else {
            liveProfileName = nil
            return
        }

        liveProfileName = profiles.first(where: { currentAccountIds.matches(profile: $0) })?.name
    }

    func saveProfile(named name: String) async -> Bool {
        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            let result = try switcher.saveCurrentProfile(named: name)
            lastActionMessage = result.warnings.isEmpty
                ? "Saved profile “\(result.profile.name)”."
                : "Saved “\(result.profile.name)” with warnings: \(result.warnings.joined(separator: " · "))"

            profiles = try profileStore.loadProfiles()
            updateCurrentAccountIds(credentials: exporter.loadCurrentCredentials())
            updateLiveProfileName()
            refreshAll()
            return true
        } catch {
            lastActionMessage = error.localizedDescription
            return false
        }
    }

    func deleteProfile(_ profile: UsageProfile) async {
        do {
            var stored = try profileStore.loadProfiles()
            stored.removeAll { $0.name == profile.name }
            try profileStore.saveProfiles(stored)

            profiles = stored
            snapshotsByProfileName.removeValue(forKey: profile.name)
            updateCurrentAccountIds(credentials: exporter.loadCurrentCredentials())
            updateLiveProfileName()
            lastActionMessage = "Deleted profile “\(profile.name)”."
            refreshAll()
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }

    func switchToProfile(_ profile: UsageProfile) async {
        switchingProfileName = profile.name
        defer { switchingProfileName = nil }

        do {
            let result = try switcher.switchToProfile(profile)
            var flags: [String] = []
            if result.claudeSwitched { flags.append("Claude") }
            if result.codexSwitched { flags.append("Codex") }
            if result.geminiSwitched { flags.append("Gemini") }

            let switchedSummary = flags.isEmpty ? "No files copied." : "Switched: \(flags.joined(separator: ", "))."
            let warningsSummary = result.warnings.isEmpty ? nil : "Warnings: \(result.warnings.joined(separator: " · "))"
            let credentials = exporter.loadCurrentCredentials()
            updateCurrentAccountIds(credentials: credentials)
            updateLiveProfileName()

            let claudeCodeEnvMessage = await applyClaudeCodeTokenForAccount(accountId: currentAccountIds.claude)
            lastActionMessage = [switchedSummary, warningsSummary, claudeCodeEnvMessage]
                .compactMap { $0 }
                .joined(separator: " ")

            refreshAll()
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }

    func saveClaudeCodeToken(accountId: String, token: String) async {
        do {
            try await claudeCodeTokenStore.saveToken(accountId: accountId, token: token)
            await reloadClaudeCodeTokenStatuses(silent: true)
            let displayAccountId = UsageAccountIdFormatter.displayAccountId(
                provider: .claude,
                email: lastKnownEmailByAccountId[accountId],
                claudeIsTeam: lastKnownClaudeIsTeamByAccountId[accountId]
            ) ?? accountId
            var message = "Saved Claude Code token for \(displayAccountId)."

            if currentAccountIds.claude == accountId,
               let envMessage = await applyClaudeCodeTokenForAccount(accountId: accountId) {
                message += " \(envMessage)"
            }

            lastActionMessage = message
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }

    func clearClaudeCodeToken(accountId: String) async {
        do {
            try await claudeCodeTokenStore.deleteToken(accountId: accountId)
            await reloadClaudeCodeTokenStatuses(silent: true)
            let displayAccountId = UsageAccountIdFormatter.displayAccountId(
                provider: .claude,
                email: lastKnownEmailByAccountId[accountId],
                claudeIsTeam: lastKnownClaudeIsTeamByAccountId[accountId]
            ) ?? accountId
            var message = "Cleared Claude Code token for \(displayAccountId)."

            if currentAccountIds.claude == accountId,
               let envMessage = await applyClaudeCodeTokenForAccount(accountId: accountId) {
                message += " \(envMessage)"
            }

            lastActionMessage = message
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }

    // MARK: - Claude Code Token Integration

    private func reloadClaudeCodeTokenStatuses(silent: Bool) async {
        do {
            claudeCodeTokenStatusByAccountId = try await claudeCodeTokenStore.statusSnapshot()
        } catch {
            if !silent {
                lastActionMessage = error.localizedDescription
            }
        }
    }

    func setClaudeCodeTokenEnabled(accountId: String, enabled: Bool) async {
        do {
            if let current = claudeCodeTokenStatusByAccountId[accountId], current.isSet {
                claudeCodeTokenStatusByAccountId[accountId] = ClaudeCodeTokenStatus(
                    isSet: current.isSet,
                    isEnabled: enabled
                )
            }
            try await claudeCodeTokenStore.setEnabled(accountId: accountId, enabled: enabled)
            await reloadClaudeCodeTokenStatuses(silent: true)

            let displayAccountId = UsageAccountIdFormatter.displayAccountId(
                provider: .claude,
                email: lastKnownEmailByAccountId[accountId],
                claudeIsTeam: lastKnownClaudeIsTeamByAccountId[accountId]
            ) ?? accountId

            var message = "Claude Code token \(enabled ? "enabled" : "disabled") for \(displayAccountId)."

            if currentAccountIds.claude == accountId,
               let envMessage = await applyClaudeCodeTokenForAccount(accountId: accountId) {
                message += " \(envMessage)"
            }

            lastActionMessage = message
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }

    private func applyClaudeCodeTokenForAccount(accountId: String?) async -> String? {
        let envVarName = "CLAUDE_CODE_OAUTH_TOKEN"

        var messages: [String] = []
        let token: String?
        if let accountId {
            do {
                token = try await claudeCodeTokenStore.loadTokenIfEnabled(accountId: accountId)
            } catch {
                messages.append(error.localizedDescription)
                token = nil
            }
        } else {
            token = nil
        }

        // Always update the current app process too; child processes inherit this.
        if let token {
            if setenv(envVarName, token, 1) != 0 {
                messages.append("setenv failed: \(String(cString: strerror(errno)))")
            }
        } else {
            if unsetenv(envVarName) != 0 {
                messages.append("unsetenv failed: \(String(cString: strerror(errno)))")
            }
        }

        let launchctlArgs: [String]
        if let token {
            launchctlArgs = ["setenv", envVarName, token]
        } else {
            launchctlArgs = ["unsetenv", envVarName]
        }

        if let message = await runLaunchctl(arguments: launchctlArgs) {
            messages.append("launchctl \(message)")
        }

        guard !messages.isEmpty else { return nil }
        return "Claude Code env update: \(messages.joined(separator: " · "))"
    }

    private func runLaunchctl(arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .nonEmptyOrNil

                        if let stderr {
                            continuation.resume(returning: "exit \(process.terminationStatus): \(stderr)")
                        } else {
                            continuation.resume(returning: "exit \(process.terminationStatus)")
                        }
                        return
                    }

                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }
}

struct UsageDashboardView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var model: UsageDashboardViewModel

    private enum UsageTab: Hashable {
        case dashboard
        case current
        case profile(String)
    }

    @State private var isSaveSheetPresented = false
    @State private var newProfileName = ""
    @State private var pendingSwitchProfile: UsageProfile?
    @State private var pendingDeleteProfile: UsageProfile?
    @State private var selectedTab: UsageTab = .dashboard
    @State private var now = Date()
    @State private var previousLiveProfileName: String?
    @State private var claudeCodeTokenEditor: ClaudeCodeTokenEditorState?
    @State private var claudeCodeTokenDraft = ""

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            header

            if let message = model.lastActionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal, 6)
            }

            profilesSection

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.horizontal, 6)

            sessionsPreviewSection
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(clock) { now = $0 }
        .onAppear {
            model.startBackgroundRefreshIfNeeded()
            previousLiveProfileName = model.liveProfileName
        }
        .onChange(of: model.liveProfileName) { newValue in
            let oldValue = previousLiveProfileName
            previousLiveProfileName = newValue
            reconcileSelectionForLiveProfileChange(oldLiveProfileName: oldValue, newLiveProfileName: newValue)
        }
        .onChange(of: model.profiles.map { $0.name }) { _ in
            ensureSelectedTabExists()
        }
        .confirmationDialog(
            "Switch Profile (Experimental)",
            isPresented: Binding(
                get: { pendingSwitchProfile != nil },
                set: { if !$0 { pendingSwitchProfile = nil } }
            )
        ) {
            Button("Switch", role: .destructive) {
                guard let profile = pendingSwitchProfile else { return }
                pendingSwitchProfile = nil
                Task { await model.switchToProfile(profile) }
            }
            Button("Cancel", role: .cancel) {
                pendingSwitchProfile = nil
            }
        } message: {
            if let profile = pendingSwitchProfile {
                Text("This will overwrite your active CLI credentials with “\(profile.name)”. Best-effort only.")
            } else {
                Text("This will overwrite your active CLI credentials. Best-effort only.")
            }
        }
        .confirmationDialog(
            "Delete Profile",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let profile = pendingDeleteProfile else { return }
                pendingDeleteProfile = nil
                Task { await model.deleteProfile(profile) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteProfile = nil
            }
        } message: {
            if let profile = pendingDeleteProfile {
                Text("This will remove “\(profile.name)” from saved profiles. Credential snapshots under `~/.agent-island/accounts/` will be kept.")
            } else {
                Text("This will remove the selected profile from saved profiles.")
            }
        }
        .sheet(isPresented: $isSaveSheetPresented) {
            SaveProfileSheet(
                isSaving: model.isSavingProfile,
                name: $newProfileName,
                onCancel: { isSaveSheetPresented = false },
                onSave: {
                    Task {
                        let ok = await model.saveProfile(named: newProfileName)
                        if ok {
                            newProfileName = ""
                            isSaveSheetPresented = false
                        }
                    }
                }
            )
        }
        .sheet(item: $claudeCodeTokenEditor) { state in
            ClaudeCodeTokenSheet(
                accountId: state.accountId,
                displayAccountId: state.displayAccountId,
                email: state.email,
                token: $claudeCodeTokenDraft,
                onCancel: {
                    claudeCodeTokenDraft = ""
                    claudeCodeTokenEditor = nil
                },
                onClear: {
                    Task {
                        await model.clearClaudeCodeToken(accountId: state.accountId)
                        claudeCodeTokenDraft = ""
                        claudeCodeTokenEditor = nil
                    }
                },
                onSave: {
                    let token = claudeCodeTokenDraft
                    Task {
                        await model.saveClaudeCodeToken(accountId: state.accountId, token: token)
                        claudeCodeTokenDraft = ""
                        claudeCodeTokenEditor = nil
                    }
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Profiles")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            Button {
                isSaveSheetPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Button {
                refreshSelectedTab()
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 6)
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.loadErrorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(TerminalColors.red)
                    .padding(.horizontal, 6)
            }

            if model.profiles.isEmpty {
                VStack(spacing: 10) {
                    UsageDashboardPanel(
                        title: model.currentSnapshot?.profileName ?? "Current",
                        badge: "UNSAVED",
                        snapshot: model.currentSnapshot,
                        accountIds: model.currentAccountIds,
                        now: now,
                        showSwitch: false,
                        isSwitching: false,
                        onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                        onClearClaudeCodeToken: clearClaudeCodeToken,
                        claudeCodeTokenStatus: model.currentAccountIds.claude.flatMap { model.claudeCodeTokenStatusByAccountId[$0] },
                        onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled,
                        onSwitch: {},
                        onDelete: nil
                    )
                        .padding(.horizontal, 6)
                    emptyProfilesState
                }
            } else {
                VStack(spacing: 10) {
                    profileTabs
                    selectedProfileSection
                }
            }
        }
    }

    private var profileTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                profileTabButton(
                    title: "Dashboard",
                    badge: "ALL",
                    isSelected: selectedTab == .dashboard
                ) {
                    selectTab(.dashboard)
                }

                if model.liveProfileName == nil {
                    profileTabButton(
                        title: "Current",
                        badge: "LIVE",
                        isSelected: selectedTab == .current
                    ) {
                        selectTab(.current)
                    }
                }

                ForEach(model.profiles) { profile in
                    profileTabButton(
                        title: profile.name,
                        badge: profile.name == model.liveProfileName ? "LIVE" : nil,
                        isSelected: selectedTab == .profile(profile.name)
                    ) {
                        selectTab(.profile(profile.name))
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func profileTabButton(
        title: String,
        badge: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(isSelected ? 0.85 : 0.55))
                    .lineLimit(1)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(isSelected ? 0.55 : 0.35))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(isSelected ? 0.08 : 0.06))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func selectTab(_ tab: UsageTab) {
        selectedTab = tab
        refreshSelectedTab()
    }

    private func refreshSelectedTab() {
        switch selectedTab {
        case .dashboard:
            model.refreshAll()
        case .current:
            model.refresh(selectedProfileName: nil)
        case .profile(let name):
            model.refresh(selectedProfileName: name)
        }
    }

    private func reconcileSelectionForLiveProfileChange(
        oldLiveProfileName: String?,
        newLiveProfileName: String?
    ) {
        switch selectedTab {
        case .current:
            if let newLiveProfileName {
                selectedTab = .profile(newLiveProfileName)
            }
        case .profile(let name):
            guard let oldLiveProfileName, name == oldLiveProfileName else { break }
            if let newLiveProfileName {
                selectedTab = .profile(newLiveProfileName)
            } else {
                selectedTab = .current
            }
        default:
            break
        }

        ensureSelectedTabExists()
    }

    private func ensureSelectedTabExists() {
        switch selectedTab {
        case .profile(let name):
            if !model.profiles.contains(where: { $0.name == name }) {
                selectedTab = .dashboard
            }
        case .current:
            if let liveProfileName = model.liveProfileName {
                selectedTab = .profile(liveProfileName)
            }
        default:
            break
        }
    }

    private var selectedProfileSection: some View {
        Group {
            switch selectedTab {
            case .dashboard:
                accountsDashboardGrid
            case .current:
                UsageDashboardPanel(
                    title: model.currentSnapshot?.profileName ?? "Current",
                    badge: "UNSAVED",
                    snapshot: model.currentSnapshot,
                    accountIds: model.currentAccountIds,
                    now: now,
                    showSwitch: false,
                    isSwitching: false,
                    onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                    onClearClaudeCodeToken: clearClaudeCodeToken,
                    claudeCodeTokenStatus: model.currentAccountIds.claude.flatMap { model.claudeCodeTokenStatusByAccountId[$0] },
                    onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled,
                    onSwitch: {},
                    onDelete: nil
                )
            case .profile(let name):
                if let profile = model.profiles.first(where: { $0.name == name }) {
                    let accountIds = UsageAccountIdSet(
                        claude: profile.claudeAccountId,
                        codex: profile.codexAccountId,
                        gemini: profile.geminiAccountId
                    )
                    UsageDashboardPanel(
                        title: profile.name,
                        badge: profile.name == model.liveProfileName ? "LIVE" : nil,
                        snapshot: model.snapshotsByProfileName[profile.name],
                        accountIds: accountIds,
                        now: now,
                        showSwitch: true,
                        isSwitching: model.switchingProfileName == profile.name,
                        onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                        onClearClaudeCodeToken: clearClaudeCodeToken,
                        claudeCodeTokenStatus: accountIds.claude.flatMap { model.claudeCodeTokenStatusByAccountId[$0] },
                        onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled,
                        onSwitch: { pendingSwitchProfile = profile },
                        onDelete: { pendingDeleteProfile = profile }
                    )
                } else {
                    UsageDashboardPanel(
                        title: model.currentSnapshot?.profileName ?? "Current",
                        badge: "UNSAVED",
                        snapshot: model.currentSnapshot,
                        accountIds: model.currentAccountIds,
                        now: now,
                        showSwitch: false,
                        isSwitching: false,
                        onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                        onClearClaudeCodeToken: clearClaudeCodeToken,
                        claudeCodeTokenStatus: model.currentAccountIds.claude.flatMap { model.claudeCodeTokenStatusByAccountId[$0] },
                        onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled,
                        onSwitch: {},
                        onDelete: nil
                    )
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var accountsDashboardGrid: some View {
        let normalTiles = dashboardTiles.filter { !isAuthExpiredError($0, now: now) }
        let expiredTiles = dashboardTiles.filter { isAuthExpiredError($0, now: now) }

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                UsageAccountTileGrid(
                    tiles: normalTiles,
                    columns: dashboardColumns,
                    now: now,
                    onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                    onClearClaudeCodeToken: clearClaudeCodeToken,
                    claudeCodeTokenStatusByAccountId: model.claudeCodeTokenStatusByAccountId,
                    onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled
                )

                if !normalTiles.isEmpty, !expiredTiles.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                }

                UsageAccountTileGrid(
                    tiles: expiredTiles,
                    columns: dashboardColumns,
                    now: now,
                    onEditClaudeCodeToken: presentClaudeCodeTokenEditor,
                    onClearClaudeCodeToken: clearClaudeCodeToken,
                    claudeCodeTokenStatusByAccountId: model.claudeCodeTokenStatusByAccountId,
                    onSetClaudeCodeTokenEnabled: setClaudeCodeTokenEnabled
                )
            }
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func isAuthExpiredError(_ tile: UsageAccountTile, now: Date) -> Bool {
        guard let refresh = tile.tokenRefresh else { return false }
        guard refresh.expiresAt <= now else { return false }

        if tile.info?.error == true { return true }
        if tile.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil != nil { return true }
        return false
    }

    private var dashboardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 160), spacing: 10), count: 3)
    }

    private var dashboardTiles: [UsageAccountTile] {
        var tilesByKey: [String: UsageAccountTile] = [:]

        func providerOrder(_ provider: UsageProvider) -> Int {
            switch provider {
            case .claude: return 0
            case .codex: return 1
            case .gemini: return 2
            }
        }

        func score(_ tile: UsageAccountTile) -> Int {
            var value = 0
            if let email = tile.email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil { value += 3 }
            if let tier = tile.tier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil { value += 1 }
            if tile.errorMessage == nil { value += 2 }
            if let info = tile.info, info.available, !info.error { value += 4 }
            if tile.info != nil { value += 1 }
            return value
        }

        func consider(_ tile: UsageAccountTile) {
            if let existing = tilesByKey[tile.id] {
                if score(tile) > score(existing) {
                    tilesByKey[tile.id] = tile
                }
            } else {
                tilesByKey[tile.id] = tile
            }
        }

        for profile in model.profiles {
            let snapshot = model.snapshotsByProfileName[profile.name]

            if let accountId = profile.claudeAccountId {
                consider(
                    UsageAccountTile(
                        id: "claude:\(accountId)",
                        provider: .claude,
                        accountId: accountId,
                        label: profile.name,
                        email: snapshot?.identities.claudeEmail,
                        tier: snapshot?.identities.claudeTier,
                        claudeIsTeam: snapshot?.identities.claudeIsTeam,
                        tokenRefresh: snapshot?.tokenRefresh.claude,
                        info: snapshot?.output?.claude,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }

            if let accountId = profile.codexAccountId {
                consider(
                    UsageAccountTile(
                        id: "codex:\(accountId)",
                        provider: .codex,
                        accountId: accountId,
                        label: profile.name,
                        email: snapshot?.identities.codexEmail,
                        tier: nil,
                        claudeIsTeam: nil,
                        tokenRefresh: snapshot?.tokenRefresh.codex,
                        info: snapshot?.output?.codex,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }

            if let accountId = profile.geminiAccountId {
                consider(
                    UsageAccountTile(
                        id: "gemini:\(accountId)",
                        provider: .gemini,
                        accountId: accountId,
                        label: profile.name,
                        email: snapshot?.identities.geminiEmail,
                        tier: nil,
                        claudeIsTeam: nil,
                        tokenRefresh: snapshot?.tokenRefresh.gemini,
                        info: snapshot?.output?.gemini,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }
        }

        // Include the live "Current" credentials in the global dashboard as well, since they may not be saved as a profile.
        if model.currentAccountIds.hasAny {
            let snapshot = model.currentSnapshot

            if let accountId = model.currentAccountIds.claude {
                consider(
                    UsageAccountTile(
                        id: "claude:\(accountId)",
                        provider: .claude,
                        accountId: accountId,
                        label: "Current",
                        email: snapshot?.identities.claudeEmail,
                        tier: snapshot?.identities.claudeTier,
                        claudeIsTeam: snapshot?.identities.claudeIsTeam,
                        tokenRefresh: snapshot?.tokenRefresh.claude,
                        info: snapshot?.output?.claude,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }

            if let accountId = model.currentAccountIds.codex {
                consider(
                    UsageAccountTile(
                        id: "codex:\(accountId)",
                        provider: .codex,
                        accountId: accountId,
                        label: "Current",
                        email: snapshot?.identities.codexEmail,
                        tier: nil,
                        claudeIsTeam: nil,
                        tokenRefresh: snapshot?.tokenRefresh.codex,
                        info: snapshot?.output?.codex,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }

            if let accountId = model.currentAccountIds.gemini {
                consider(
                    UsageAccountTile(
                        id: "gemini:\(accountId)",
                        provider: .gemini,
                        accountId: accountId,
                        label: "Current",
                        email: snapshot?.identities.geminiEmail,
                        tier: nil,
                        claudeIsTeam: nil,
                        tokenRefresh: snapshot?.tokenRefresh.gemini,
                        info: snapshot?.output?.gemini,
                        errorMessage: snapshot?.errorMessage
                    )
                )
            }
        }

        return tilesByKey.values.sorted { a, b in
            let pa = providerOrder(a.provider)
            let pb = providerOrder(b.provider)
            if pa != pb { return pa < pb }

            func emailKey(_ email: String?) -> String? {
                guard let email else { return nil }
                return email
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .nonEmptyOrNil
            }

            let ea = emailKey(a.email) ?? a.id
            let eb = emailKey(b.email) ?? b.id
            return ea < eb
        }
    }

    private var emptyProfilesState: some View {
        VStack(spacing: 8) {
            Text("No saved profiles yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("“Current” shows your active CLI logins. Use “Save Profile” to snapshot them.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.horizontal, 10)
    }

    private var sessionsPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.showSessions()
            } label: {
                HStack(spacing: 8) {
                    Text("Claude Sessions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)

            if previewSessions.isEmpty {
                Text("No sessions")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(previewSessions) { session in
                        Button {
                            viewModel.showSessions()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(color(for: session.phase))
                                    .frame(width: 6, height: 6)
                                Text(session.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private var previewSessions: [SessionState] {
        sessionMonitor.instances
            .sorted { a, b in
                let dateA = a.lastUserMessageDate ?? a.lastActivity
                let dateB = b.lastUserMessageDate ?? b.lastActivity
                return dateA > dateB
            }
            .prefix(3)
            .map { $0 }
    }

    private func color(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval, .processing, .compacting:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return TerminalColors.dim
        }
    }

    private struct ClaudeCodeTokenEditorState: Identifiable {
        let id = UUID()
        let accountId: String
        let displayAccountId: String
        let email: String?
    }

    private func presentClaudeCodeTokenEditor(accountId: String) {
        claudeCodeTokenDraft = ""
        let email = claudeEmail(for: accountId)
        let isTeam = claudeIsTeam(for: accountId)
        let displayAccountId = UsageAccountIdFormatter.displayAccountId(
            provider: .claude,
            email: email,
            claudeIsTeam: isTeam
        ) ?? accountId
        claudeCodeTokenEditor = ClaudeCodeTokenEditorState(
            accountId: accountId,
            displayAccountId: displayAccountId,
            email: email
        )
    }

    private func clearClaudeCodeToken(accountId: String) {
        Task { await model.clearClaudeCodeToken(accountId: accountId) }
    }

    private func setClaudeCodeTokenEnabled(accountId: String, enabled: Bool) {
        Task { await model.setClaudeCodeTokenEnabled(accountId: accountId, enabled: enabled) }
    }

    private func claudeEmail(for accountId: String) -> String? {
        dashboardTiles
            .first(where: { $0.provider == .claude && $0.accountId == accountId })?
            .email
    }

    private func claudeIsTeam(for accountId: String) -> Bool? {
        dashboardTiles
            .first(where: { $0.provider == .claude && $0.accountId == accountId })?
            .claudeIsTeam
    }
}

enum UsageProvider: Hashable {
    case claude
    case codex
    case gemini

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
}

enum UsageWindow: CaseIterable {
    case fiveHour
    case twentyFourHour
    case sevenDay

    var label: String {
        switch self {
        case .fiveHour: "5h"
        case .twentyFourHour: "24h"
        case .sevenDay: "7d"
        }
    }
}

private enum UsageAccountIdFormatter {
    static func displayAccountId(provider: UsageProvider, email: String?, claudeIsTeam: Bool?) -> String? {
        guard let emailSlug = emailSlug(email) else { return nil }

        switch provider {
        case .claude:
            if claudeIsTeam == true {
                return "acct_claude_team_\(emailSlug)"
            }
            return "acct_claude_\(emailSlug)"
        case .codex:
            return "acct_codex_\(emailSlug)"
        case .gemini:
            return "acct_gemini_\(emailSlug)"
        }
    }

    private static func emailSlug(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil else { return nil }

        let lowered = email.lowercased()
        var output: [UInt8] = []
        output.reserveCapacity(lowered.utf8.count)

        var lastWasUnderscore = false
        for byte in lowered.utf8 {
            let isDigit = byte >= 48 && byte <= 57
            let isLower = byte >= 97 && byte <= 122
            if isDigit || isLower {
                output.append(byte)
                lastWasUnderscore = false
            } else {
                guard !lastWasUnderscore else { continue }
                output.append(95) // "_"
                lastWasUnderscore = true
            }
        }

        let raw = String(decoding: output, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.nonEmptyOrNil
    }
}

private struct UsageAccountTile: Identifiable {
    let id: String
    let provider: UsageProvider
    let accountId: String
    let label: String
    let email: String?
    let tier: String?
    let claudeIsTeam: Bool?
    let tokenRefresh: TokenRefreshInfo?
    let info: CLIUsageInfo?
    let errorMessage: String?
}

private struct UsageAccountTileRowHeightsPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        for (rowIndex, rowHeight) in nextValue() {
            value[rowIndex] = max(value[rowIndex] ?? 0, rowHeight)
        }
    }
}

private struct UsageAccountTileGrid: View {
    let tiles: [UsageAccountTile]
    let columns: [GridItem]
    let now: Date
    let onEditClaudeCodeToken: ((String) -> Void)?
    let onClearClaudeCodeToken: ((String) -> Void)?
    let claudeCodeTokenStatusByAccountId: [String: ClaudeCodeTokenStatus]
    let onSetClaudeCodeTokenEnabled: ((String, Bool) -> Void)?

    @State private var rowHeights: [Int: CGFloat] = [:]

    private struct IndexedTile: Identifiable {
        let index: Int
        let tile: UsageAccountTile

        var id: String { tile.id }
    }

    var body: some View {
        let indexedTiles = tiles.enumerated().map { IndexedTile(index: $0.offset, tile: $0.element) }
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(indexedTiles, id: \.id) { indexed in
                let rowIndex = rowIndex(for: indexed.index)
                UsageAccountTileCard(
                    tile: indexed.tile,
                    now: now,
                    forcedHeight: rowHeights[rowIndex],
                    rowIndex: rowIndex,
                    onEditClaudeCodeToken: onEditClaudeCodeToken,
                    onClearClaudeCodeToken: onClearClaudeCodeToken,
                    claudeCodeTokenStatus: indexed.tile.provider == .claude
                        ? claudeCodeTokenStatusByAccountId[indexed.tile.accountId]
                        : nil,
                    onSetClaudeCodeTokenEnabled: onSetClaudeCodeTokenEnabled
                )
            }
        }
        .onPreferenceChange(UsageAccountTileRowHeightsPreferenceKey.self) { newHeights in
            if rowHeights != newHeights {
                rowHeights = newHeights
            }
        }
    }

    private func rowIndex(for tileIndex: Int) -> Int {
        guard !columns.isEmpty else { return 0 }
        return tileIndex / columns.count
    }
}

private struct UsageAccountTileCard: View {
    let tile: UsageAccountTile
    let now: Date
    let forcedHeight: CGFloat?
    let rowIndex: Int?
    let onEditClaudeCodeToken: ((String) -> Void)?
    let onClearClaudeCodeToken: ((String) -> Void)?
    let claudeCodeTokenStatus: ClaudeCodeTokenStatus?
    let onSetClaudeCodeTokenEnabled: ((String, Bool) -> Void)?

    @State private var isHovered = false

    init(
        tile: UsageAccountTile,
        now: Date,
        forcedHeight: CGFloat? = nil,
        rowIndex: Int? = nil,
        onEditClaudeCodeToken: ((String) -> Void)?,
        onClearClaudeCodeToken: ((String) -> Void)?,
        claudeCodeTokenStatus: ClaudeCodeTokenStatus?,
        onSetClaudeCodeTokenEnabled: ((String, Bool) -> Void)?
    ) {
        self.tile = tile
        self.now = now
        self.forcedHeight = forcedHeight
        self.rowIndex = rowIndex
        self.onEditClaudeCodeToken = onEditClaudeCodeToken
        self.onClearClaudeCodeToken = onClearClaudeCodeToken
        self.claudeCodeTokenStatus = claudeCodeTokenStatus
        self.onSetClaudeCodeTokenEnabled = onSetClaudeCodeTokenEnabled
    }

    var body: some View {
        content
            // Keep the measured content at its natural height even when we wrap it with a fixed row height.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heightReporter)
            .frame(height: forcedHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.white.opacity(0.09) : Color.white.opacity(0.06))
            )
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageProviderColumn(
                provider: tile.provider,
                accountId: tile.accountId,
                email: tile.email,
                tier: tile.tier,
                claudeIsTeam: tile.claudeIsTeam,
                tokenRefresh: tile.tokenRefresh,
                info: tile.info,
                now: now,
                onEditClaudeCodeToken: onEditClaudeCodeToken,
                onClearClaudeCodeToken: onClearClaudeCodeToken,
                claudeCodeTokenStatus: claudeCodeTokenStatus,
                onSetClaudeCodeTokenEnabled: onSetClaudeCodeTokenEnabled
            )

            Text((tile.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil) ?? " ")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.amber.opacity(0.9))
                .lineLimit(1)
                .opacity((tile.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil) == nil ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var heightReporter: some View {
        if let rowIndex {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: UsageAccountTileRowHeightsPreferenceKey.self,
                    value: [rowIndex: proxy.size.height]
                )
            }
        }
    }
}

private struct UsageDashboardPanel: View {
    let title: String
    let badge: String?
    let snapshot: UsageSnapshot?
    let accountIds: UsageAccountIdSet
    let now: Date
    let showSwitch: Bool
    let isSwitching: Bool
    let onEditClaudeCodeToken: ((String) -> Void)?
    let onClearClaudeCodeToken: ((String) -> Void)?
    let claudeCodeTokenStatus: ClaudeCodeTokenStatus?
    let onSetClaudeCodeTokenEnabled: ((String, Bool) -> Void)?
    let onSwitch: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }

            HStack(alignment: .top, spacing: 0) {
                UsageProviderColumn(
                    provider: .claude,
                    accountId: accountIds.claude,
                    email: snapshot?.identities.claudeEmail,
                    tier: snapshot?.identities.claudeTier,
                    claudeIsTeam: snapshot?.identities.claudeIsTeam,
                    tokenRefresh: snapshot?.tokenRefresh.claude,
                    info: snapshot?.output?.claude,
                    now: now,
                    onEditClaudeCodeToken: onEditClaudeCodeToken,
                    onClearClaudeCodeToken: onClearClaudeCodeToken,
                    claudeCodeTokenStatus: claudeCodeTokenStatus,
                    onSetClaudeCodeTokenEnabled: onSetClaudeCodeTokenEnabled
                )
                columnDivider
                UsageProviderColumn(
                    provider: .codex,
                    accountId: accountIds.codex,
                    email: snapshot?.identities.codexEmail,
                    tier: nil,
                    claudeIsTeam: nil,
                    tokenRefresh: snapshot?.tokenRefresh.codex,
                    info: snapshot?.output?.codex,
                    now: now,
                    onEditClaudeCodeToken: nil,
                    onClearClaudeCodeToken: nil,
                    claudeCodeTokenStatus: nil,
                    onSetClaudeCodeTokenEnabled: nil
                )
                columnDivider
                UsageProviderColumn(
                    provider: .gemini,
                    accountId: accountIds.gemini,
                    email: snapshot?.identities.geminiEmail,
                    tier: nil,
                    claudeIsTeam: nil,
                    tokenRefresh: snapshot?.tokenRefresh.gemini,
                    info: snapshot?.output?.gemini,
                    now: now,
                    onEditClaudeCodeToken: nil,
                    onClearClaudeCodeToken: nil,
                    claudeCodeTokenStatus: nil,
                    onSetClaudeCodeTokenEnabled: nil
                )
            }

            if let message = snapshot?.errorMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.amber.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.09) : Color.white.opacity(0.06))
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )
            }

            Spacer()

            if let snapshot, let fetchedAt = snapshot.fetchedAt {
                Text(timeString(fetchedAt))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(snapshot.isStale ? 0.35 : 0.45))
            }

            if showSwitch {
                Button(action: onSwitch) {
                    HStack(spacing: 6) {
                        if isSwitching {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("Switch")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSwitching)

                if let onDelete {
                    Button(action: onDelete) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Delete")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(TerminalColors.red.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(TerminalColors.red.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSwitching)
                }
            }
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.horizontal, 10)
    }

    private func timeString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

private struct UsageProviderColumn: View {
    let provider: UsageProvider
    let accountId: String?
    let email: String?
    let tier: String?
    let claudeIsTeam: Bool?
    let tokenRefresh: TokenRefreshInfo?
    let info: CLIUsageInfo?
    let now: Date
    let onEditClaudeCodeToken: ((String) -> Void)?
    let onClearClaudeCodeToken: ((String) -> Void)?
    let claudeCodeTokenStatus: ClaudeCodeTokenStatus?
    let onSetClaudeCodeTokenEnabled: ((String, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            UsageTokenRefreshRow(tokenRefresh: tokenRefresh, now: now)

            usageRows

            claudeCodeTokenFooter
        }
        .contextMenu {
            if provider == .claude, let accountId = normalizedAccountId {
                if let onEditClaudeCodeToken {
                    Button("Set Claude Code Token…") {
                        onEditClaudeCodeToken(accountId)
                    }
                }

                if let onClearClaudeCodeToken {
                    Button("Clear Claude Code Token") {
                        onClearClaudeCodeToken(accountId)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var claudeCodeTokenFooter: some View {
        if provider == .claude, let accountId = normalizedAccountId {
            VStack(spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.28))

                    Text("Claude Code Token")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if claudeCodeTokenStatus?.isSet == true, let onSetClaudeCodeTokenEnabled {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { claudeCodeTokenStatus?.isEnabled ?? false },
                                set: { onSetClaudeCodeTokenEnabled(accountId, $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: TerminalColors.red.opacity(0.85)))
                        .scaleEffect(0.8)
                    } else {
                        Text("Not set")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.22))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            UsageProviderIcon(provider: provider, size: 14)

            Text(headerTitle)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(headerTitleColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 6)

            if let tier = tierBadgeTier {
                TierBadge(provider: provider, tier: tier)
            }

            if showsClaudeTeamBadge {
                Text("TEAM")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            if let badge = statusBadge {
                Text(badge.label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(badge.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(badge.background)
                    )
            }
        }
    }

    private var tierBadgeTier: String? {
        guard let tier = resolvedTier else { return nil }

        // Only show Claude tier when we can confidently classify it.
        if provider == .claude, normalizedClaudeTierLabel(from: tier) == nil {
            return nil
        }

        return tier
    }

    private func normalizedClaudeTierLabel(from tier: String) -> String? {
        let raw = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lowered = raw.lowercased()
        let tokens = lowered.split { !($0.isLetter || $0.isNumber) }
        let hasToken: (String) -> Bool = { token in tokens.contains { $0 == token } }
        let normalized = lowered
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        if normalized.contains("max20") || (hasToken("max") && (hasToken("20x") || hasToken("20"))) { return "Max20" }
        if normalized.contains("max5") || (hasToken("max") && (hasToken("5x") || hasToken("5"))) { return "Max5" }
        if hasToken("pro") { return "Pro" }

        return nil
    }

    private var showsClaudeTeamBadge: Bool {
        provider == .claude && claudeIsTeam == true
    }

    private var normalizedAccountId: String? {
        accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }

    private var normalizedEmail: String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }

    private var headerTitle: String {
        if let normalizedEmail { return normalizedEmail }
        if let info, !info.available { return "Not installed" }
        if let normalizedAccountId { return normalizedAccountId }
        return "--"
    }

    private var headerTitleColor: Color {
        if normalizedEmail != nil { return Color.white.opacity(0.9) }
        if let info, !info.available { return TerminalColors.dim }
        if normalizedAccountId != nil { return Color.white.opacity(0.22) }
        return Color.white.opacity(0.2)
    }

    private var statusBadge: (label: String, background: Color, foreground: Color)? {
        if let info, !info.available {
            return (label: "MISS", background: Color.white.opacity(0.08), foreground: Color.white.opacity(0.45))
        }

        if isTokenExpired {
            return (label: "EXP", background: TerminalColors.amber.opacity(0.9), foreground: Color.black.opacity(0.85))
        }

        if info?.error == true {
            return (label: "ERR", background: TerminalColors.red.opacity(0.9), foreground: Color.white.opacity(0.9))
        }
        return nil
    }

    private var isTokenExpired: Bool {
        guard let tokenRefresh else { return false }
        return tokenRefresh.expiresAt <= now
    }

    private var resolvedTier: String? {
        switch provider {
        case .claude:
            return tier
        case .codex:
            return normalizeCodexTier(info?.plan)
        case .gemini:
            return inferGeminiTier(model: info?.model, plan: info?.plan)
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        switch provider {
        case .gemini:
            GeminiUsageSummaryRow(info: info, now: now)
        case .claude, .codex:
            ForEach(providerWindows, id: \.label) { window in
                UsageWindowRow(
                    window: window,
                    percentUsed: percentUsed(for: window),
                    resetAt: resetAt(for: window),
                    now: now
                )
            }
        }
    }

    private var providerWindows: [UsageWindow] {
        switch provider {
        case .gemini: return []
        case .claude, .codex: return [.fiveHour, .sevenDay]
        }
    }

    private func percentUsed(for window: UsageWindow) -> Double? {
        guard let info, info.available, !info.error else { return nil }
        switch window {
        case .fiveHour, .twentyFourHour: return info.fiveHourPercent
        case .sevenDay: return info.sevenDayPercent
        }
    }

    private func resetAt(for window: UsageWindow) -> Date? {
        guard let info, info.available, !info.error else { return nil }
        switch window {
        case .fiveHour, .twentyFourHour: return info.fiveHourReset
        case .sevenDay: return info.sevenDayReset
        }
    }

    private func normalizeCodexTier(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil else { return nil }

        let lowered = plan.lowercased()
        let tokens = lowered.split { !($0.isLetter || $0.isNumber) }
        let hasToken: (String) -> Bool = { token in tokens.contains { $0 == token } }

        if hasToken("plus") || lowered.contains("plus") { return "Plus" }
        if hasToken("pro") || lowered.contains("pro") { return "Pro" }
        return plan
    }

    private func inferGeminiTier(model: String?, plan: String?) -> String? {
        let candidates = [plan, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil }
        guard !candidates.isEmpty else { return nil }

        let lowered = candidates.joined(separator: " ").lowercased()
        if lowered.contains("pro") { return "Pro" }
        if lowered.contains("flash") { return "Flash" }
        if lowered.contains("ultra") { return "Ultra" }
        if lowered.contains("nano") { return "Nano" }
        return nil
    }
}

private struct TierBadge: View {
    let provider: UsageProvider
    let tier: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(style.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(style.background)
            )
    }

    private var label: String {
        let lowered = tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("max") && lowered.contains("20") { return "Max20" }
        if lowered.contains("max") && lowered.contains("5") { return "Max5" }
        if lowered.contains("plus") { return "Plus" }
        if lowered.contains("pro") { return "Pro" }
        if lowered.contains("flash") { return "Flash" }
        if lowered.contains("ultra") { return "Ultra" }
        if lowered.contains("nano") { return "Nano" }
        return tier
    }

    private var style: (background: Color, foreground: Color) {
        let key = label.lowercased()

        switch provider {
        case .claude:
            if key == "pro" { return (Color.white.opacity(0.9), Color.black.opacity(0.85)) }
            if key == "max5" { return (TerminalColors.amber, Color.black.opacity(0.85)) }
            if key == "max20" { return (TerminalColors.red, Color.white.opacity(0.9)) }
        case .codex:
            if key == "plus" { return (Color.white.opacity(0.9), Color.black.opacity(0.85)) }
            if key == "pro" { return (TerminalColors.red, Color.white.opacity(0.9)) }
        case .gemini:
            return (TerminalColors.blue.opacity(0.85), Color.white.opacity(0.9))
        }

        return (Color.white.opacity(0.08), Color.white.opacity(0.55))
    }
}

private struct UsageTokenRefreshRow: View {
    let tokenRefresh: TokenRefreshInfo?
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 18, alignment: .leading)

            MiniSegmentBar(
                fraction: remainingFraction,
                fillColor: barFillColor,
                emptyColor: Color.white.opacity(0.08)
            )
            .frame(height: 6)
            .frame(width: 46)

            timeRemainingText
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 46, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)
        }
        .opacity(tokenRefresh == nil ? 0.65 : 1)
    }

    private var remainingFraction: Double {
        guard let tokenRefresh else { return 0 }
        let remaining = max(0, tokenRefresh.expiresAt.timeIntervalSince(now))
        let total = max(1, tokenRefresh.lifetimeSeconds)
        return max(0, min(1, remaining / total))
    }

    private var barFillColor: Color {
        tokenRefresh == nil
            ? Color.white.opacity(0.12)
            : TerminalColors.magenta.opacity(0.85)
    }

    private var iconColor: Color {
        tokenRefresh == nil
            ? Color.white.opacity(0.25)
            : TerminalColors.magenta.opacity(0.85)
    }

    private var timeRemainingText: Text {
        let baseColor = Color.white.opacity(0.28)
        guard let tokenRefresh else { return Text("--").foregroundColor(baseColor) }
        if tokenRefresh.expiresAt <= now {
            return Text("Expired!")
                .foregroundColor(TerminalColors.amber.opacity(0.9))
        }
        let seconds = max(0, Int(tokenRefresh.expiresAt.timeIntervalSince(now)))
        return UsageDurationText.make(seconds: seconds, digitColor: baseColor)
    }
}

private struct GeminiUsageSummaryRow: View {
    let info: CLIUsageInfo?
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(modelName)
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(bucketCountString)
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 14, alignment: .trailing)

            Text(remainingPercentString)
                .foregroundColor(remainingPercentColor)
                .frame(width: 54, alignment: .trailing)

            resetsInText
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private var modelName: String {
        info?.model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? "gemini"
    }

    private var bucketCountString: String {
        guard let buckets = info?.buckets else { return "--" }
        return "\(buckets.count)"
    }

    private var remainingPercentString: String {
        guard let used = info?.fiveHourPercent else { return "--" }
        let remaining = max(0, min(100, 100 - used))
        return String(format: "%.1f%%", remaining)
    }

    private var remainingPercentColor: Color {
        guard let used = info?.fiveHourPercent else { return TerminalColors.dim }
        let remaining = max(0, min(100, 100 - used))
        if remaining < 10 { return TerminalColors.red }
        if remaining < 25 { return TerminalColors.amber }
        return TerminalColors.green
    }

    private var resetsInText: Text {
        let baseColor = Color.white.opacity(0.28)
        guard let resetAt = info?.fiveHourReset else {
            return Text("(Resets in --)")
                .foregroundColor(baseColor)
        }

        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        return Text("(").foregroundColor(baseColor)
            + Text("Resets in ").foregroundColor(baseColor)
            + UsageDurationText.make(seconds: seconds, digitColor: baseColor)
            + Text(")").foregroundColor(baseColor)
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let percentUsed: Double?
    let resetAt: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 18, alignment: .leading)

                MiniSegmentBar(
                    fraction: usageRemainingFraction,
                    fillColor: usageFillColor,
                    emptyColor: Color.white.opacity(0.08)
                )
                .frame(height: 6)
                .frame(width: 46)

                MiniSegmentBar(
                    fraction: resetRemainingFraction,
                    fillColor: TerminalColors.blue.opacity(0.85),
                    emptyColor: Color.white.opacity(0.08)
                )
                .frame(height: 6)
                .frame(width: 46)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: 18, height: 1)

                Text(remainingPercentString)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(usageTextColor)
                    .frame(width: 46, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                timeRemainingText
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 46, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)
            }
        }
    }

    private var usageRemainingFraction: Double {
        guard let percentUsed else { return 0 }
        let used = max(0, min(100, percentUsed))
        return max(0, min(1, (100 - used) / 100))
    }

    private var remainingPercentString: String {
        guard let percentUsed else { return "--" }
        let used = max(0, min(100, percentUsed))
        let remaining = max(0, min(100, 100 - used))
        return "\(Int(remaining.rounded()))%"
    }

    private var usageFillColor: Color {
        let fraction = max(0, min(1, usageRemainingFraction))
        let hue = 0.33 * fraction
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }

    private var usageTextColor: Color {
        guard percentUsed != nil else { return TerminalColors.dim }
        return usageFillColor.opacity(0.9)
    }

    private var resetRemainingFraction: Double {
        guard let resetAt, let total = windowDurationSeconds else { return 0 }
        let remaining = max(0, resetAt.timeIntervalSince(now))
        return max(0, min(1, remaining / total))
    }

    private var timeRemainingText: Text {
        let baseColor = Color.white.opacity(0.28)
        guard let resetAt else { return Text("--").foregroundColor(baseColor) }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        return UsageDurationText.make(seconds: seconds, digitColor: baseColor)
    }

    private var windowDurationSeconds: TimeInterval? {
        switch window {
        case .fiveHour:
            return 5 * 60 * 60
        case .twentyFourHour:
            return 24 * 60 * 60
        case .sevenDay:
            return 7 * 24 * 60 * 60
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MiniSegmentBar: View {
    let fraction: Double
    let fillColor: Color
    let emptyColor: Color

    var body: some View {
        GeometryReader { geo in
            let segmentCount = 10
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(segmentCount - 1)
            let segmentWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(segmentCount))
            let filledSegments = max(0, min(segmentCount, Int((fraction * Double(segmentCount)).rounded(.toNearestOrAwayFromZero))))

            HStack(spacing: spacing) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < filledSegments ? fillColor : emptyColor)
                        .frame(width: segmentWidth)
                }
            }
        }
    }
}

private struct ClaudeCodeTokenSheet: View {
    let accountId: String
    let displayAccountId: String
    let email: String?
    @Binding var token: String
    let onCancel: () -> Void
    let onClear: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                UsageProviderIcon(provider: .claude, size: 16)
                Text("Claude Code Token")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(emailLine)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(displayAccountId)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("Paste `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`. Stored locally and applied on profile switch. Not used for usage fetching.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            SecureField("CLAUDE_CODE_OAUTH_TOKEN", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium, design: .monospaced))

            HStack(spacing: 10) {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Clear", role: .destructive) { onClear() }
                Button("Save") { onSave() }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private var emailLine: String {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? "--"
    }
}

private struct SaveProfileSheet: View {
    let isSaving: Bool
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Profile")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("e.g. Work", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("This snapshots your current Claude/Codex/Gemini CLI credentials into `~/.agent-island/accounts/` and links them to the profile.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button(isSaving ? "Saving…" : "Save") { onSave() }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
