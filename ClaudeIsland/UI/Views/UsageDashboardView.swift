import Combine
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

    private var refreshTask: Task<Void, Never>?
    private var autoRefreshCancellable: AnyCancellable?
    private let autoRefreshIntervalSeconds: TimeInterval = 10 * 60
    private var backgroundRefreshStarted = false

    init(accountStore: AccountStore = AccountStore()) {
        self.accountStore = accountStore
        self.profileStore = ProfileStore(accountStore: accountStore)
        self.fetcher = UsageFetcher(accountStore: accountStore, cache: UsageCache())
        let exporter = CredentialExporter()
        self.exporter = exporter
        self.switcher = ProfileSwitcher(accountStore: accountStore, exporter: exporter)
    }

    func startBackgroundRefreshIfNeeded() {
        guard !backgroundRefreshStarted else { return }
        backgroundRefreshStarted = true
        load()
        startAutoRefresh()
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
            currentAccountIds = computeAccountIds(credentials: credentials)
            updateLiveProfileName()
            currentSnapshot = await fetcher.fetchCurrentSnapshot(credentials: credentials)

            for profile in profilesToRefresh {
                if Task.isCancelled { break }
                let snapshot = await fetcher.fetchSnapshot(for: profile)
                snapshotsByProfileName[profile.name] = snapshot
            }
        }
    }

    private func computeAccountIds(credentials: ExportCredentials) -> UsageAccountIdSet {
        UsageAccountIdSet(
            claude: credentials.claude.map { UsageCredentialHasher.fingerprint(service: .claude, data: $0).accountId },
            codex: credentials.codex.map { UsageCredentialHasher.fingerprint(service: .codex, data: $0).accountId },
            gemini: credentials.gemini.map { UsageCredentialHasher.fingerprint(service: .gemini, data: $0).accountId }
        )
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
            currentAccountIds = computeAccountIds(credentials: exporter.loadCurrentCredentials())
            updateLiveProfileName()
            refreshAll()
            return true
        } catch {
            lastActionMessage = error.localizedDescription
            return false
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
            lastActionMessage = [switchedSummary, warningsSummary].compactMap { $0 }.joined(separator: " ")

            currentAccountIds = computeAccountIds(credentials: exporter.loadCurrentCredentials())
            updateLiveProfileName()
            refreshAll()
        } catch {
            lastActionMessage = error.localizedDescription
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
    @State private var selectedTab: UsageTab = .dashboard
    @State private var now = Date()
    @State private var previousLiveProfileName: String?

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
                        now: now,
                        showSwitch: false,
                        isSwitching: false,
                        onSwitch: {}
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
                    now: now,
                    showSwitch: false,
                    isSwitching: false,
                    onSwitch: {}
                )
            case .profile(let name):
                if let profile = model.profiles.first(where: { $0.name == name }) {
                    UsageDashboardPanel(
                        title: profile.name,
                        badge: profile.name == model.liveProfileName ? "LIVE" : nil,
                        snapshot: model.snapshotsByProfileName[profile.name],
                        now: now,
                        showSwitch: true,
                        isSwitching: model.switchingProfileName == profile.name,
                        onSwitch: { pendingSwitchProfile = profile }
                    )
                } else {
                    UsageDashboardPanel(
                        title: model.currentSnapshot?.profileName ?? "Current",
                        badge: "UNSAVED",
                        snapshot: model.currentSnapshot,
                        now: now,
                        showSwitch: false,
                        isSwitching: false,
                        onSwitch: {}
                    )
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var accountsDashboardGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: dashboardColumns, spacing: 10) {
                ForEach(dashboardTiles) { tile in
                    UsageAccountTileCard(tile: tile, now: now)
                }
            }
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                        label: profile.name,
                        email: snapshot?.identities.claudeEmail,
                        tier: snapshot?.identities.claudeTier,
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
                        label: profile.name,
                        email: snapshot?.identities.codexEmail,
                        tier: nil,
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
                        label: profile.name,
                        email: snapshot?.identities.geminiEmail,
                        tier: nil,
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

private struct UsageAccountTile: Identifiable {
    let id: String
    let provider: UsageProvider
    let label: String
    let email: String?
    let tier: String?
    let info: CLIUsageInfo?
    let errorMessage: String?
}

private struct UsageAccountTileCard: View {
    let tile: UsageAccountTile
    let now: Date

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageProviderColumn(
                provider: tile.provider,
                email: tile.email,
                tier: tile.tier,
                info: tile.info,
                now: now
            )

            Text((tile.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil) ?? " ")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.amber.opacity(0.9))
                .lineLimit(1)
                .opacity((tile.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil) == nil ? 0 : 1)
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
}

private struct UsageDashboardPanel: View {
    let title: String
    let badge: String?
    let snapshot: UsageSnapshot?
    let now: Date
    let showSwitch: Bool
    let isSwitching: Bool
    let onSwitch: () -> Void

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
                    email: snapshot?.identities.claudeEmail,
                    tier: snapshot?.identities.claudeTier,
                    info: snapshot?.output?.claude,
                    now: now
                )
                columnDivider
                UsageProviderColumn(
                    provider: .codex,
                    email: snapshot?.identities.codexEmail,
                    tier: nil,
                    info: snapshot?.output?.codex,
                    now: now
                )
                columnDivider
                UsageProviderColumn(
                    provider: .gemini,
                    email: snapshot?.identities.geminiEmail,
                    tier: nil,
                    info: snapshot?.output?.gemini,
                    now: now
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
    let email: String?
    let tier: String?
    let info: CLIUsageInfo?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(emailLineText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(emailLineColor)
                .lineLimit(1)
                .truncationMode(.middle)

            usageRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            UsageProviderIcon(provider: provider, size: 14)

            Spacer(minLength: 6)

            if let tier = resolvedTier {
                TierBadge(provider: provider, tier: tier)
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

    private var normalizedEmail: String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }

    private var emailLineText: String {
        if let normalizedEmail { return normalizedEmail }
        if let info, !info.available { return "Not installed" }
        return "--"
    }

    private var emailLineColor: Color {
        if normalizedEmail != nil { return Color.white.opacity(0.35) }
        if let info, !info.available { return TerminalColors.dim }
        return Color.white.opacity(0.2)
    }

    private var statusBadge: (label: String, background: Color, foreground: Color)? {
        guard let info else { return nil }
        if !info.available {
            return (label: "MISSING", background: Color.white.opacity(0.08), foreground: Color.white.opacity(0.45))
        }
        if info.error {
            return (label: "ERR", background: TerminalColors.amber.opacity(0.9), foreground: Color.black.opacity(0.85))
        }
        return nil
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

            Text("This snapshots your current Claude/Codex/Gemini CLI credentials into `~/.claude-island/accounts/` and links them to the profile.")
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
