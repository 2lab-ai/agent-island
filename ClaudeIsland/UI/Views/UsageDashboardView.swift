import Combine
import Foundation
import SwiftUI

@MainActor
final class UsageDashboardViewModel: ObservableObject {
    @Published var profiles: [UsageProfile] = []
    @Published var currentSnapshot: UsageSnapshot?
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

    init(accountStore: AccountStore = AccountStore()) {
        self.accountStore = accountStore
        self.profileStore = ProfileStore(accountStore: accountStore)
        self.fetcher = UsageFetcher(accountStore: accountStore, cache: UsageCache())
        let exporter = CredentialExporter()
        self.exporter = exporter
        self.switcher = ProfileSwitcher(accountStore: accountStore, exporter: exporter)
    }

    func load() {
        do {
            loadErrorMessage = nil
            profiles = try profileStore.loadProfiles()
        } catch {
            loadErrorMessage = error.localizedDescription
            profiles = []
        }

        refresh()
    }

    func refresh(selectedProfileName: String? = nil) {
        refreshTask?.cancel()
        isRefreshing = true

        let profilesToRefresh: [UsageProfile]
        if let selectedProfileName,
           let profile = profiles.first(where: { $0.name == selectedProfileName }) {
            profilesToRefresh = [profile]
        } else {
            profilesToRefresh = []
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }

            let credentials = exporter.loadCurrentCredentials()
            currentSnapshot = await fetcher.fetchCurrentSnapshot(credentials: credentials)

            for profile in profilesToRefresh {
                if Task.isCancelled { break }
                let snapshot = await fetcher.fetchSnapshot(for: profile)
                snapshotsByProfileName[profile.name] = snapshot
            }
        }
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
            refresh()
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
        } catch {
            lastActionMessage = error.localizedDescription
        }
    }
}

struct UsageDashboardView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var model = UsageDashboardViewModel()

    @State private var isSaveSheetPresented = false
    @State private var newProfileName = ""
    @State private var pendingSwitchProfile: UsageProfile?
    @State private var selectedProfileName: String?

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
        .onAppear { model.load() }
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
                Text("구독 사용량")
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
                model.refresh(selectedProfileName: selectedProfileName)
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
                    CurrentUsageRow(snapshot: model.currentSnapshot)
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
                    title: "Current",
                    badge: "LIVE",
                    isSelected: selectedProfileName == nil
                ) {
                    selectProfileTab(nil)
                }

                ForEach(model.profiles) { profile in
                    profileTabButton(
                        title: profile.name,
                        badge: nil,
                        isSelected: selectedProfileName == profile.name
                    ) {
                        selectProfileTab(profile.name)
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

    private func selectProfileTab(_ name: String?) {
        selectedProfileName = name
        model.refresh(selectedProfileName: name)
    }

    private var selectedProfileSection: some View {
        Group {
            if let selectedProfileName,
               let profile = model.profiles.first(where: { $0.name == selectedProfileName }) {
                ProfileUsageRow(
                    profile: profile,
                    snapshot: model.snapshotsByProfileName[profile.name],
                    isSwitching: model.switchingProfileName == profile.name,
                    onSwitch: { pendingSwitchProfile = profile }
                )
            } else {
                CurrentUsageRow(snapshot: model.currentSnapshot)
            }
        }
        .padding(.horizontal, 6)
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
                    Text("클로드 세션 리스트")
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

private struct ProfileUsageRow: View {
    let profile: UsageProfile
    let snapshot: UsageSnapshot?
    let isSwitching: Bool
    let onSwitch: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                if let snapshot, let fetchedAt = snapshot.fetchedAt {
                    Text(timeString(fetchedAt))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(snapshot.isStale ? 0.35 : 0.45))
                }

                Button {
                    onSwitch()
                } label: {
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

            HStack(spacing: 10) {
                UsageServiceCard(
                    label: "Claude",
                    email: snapshot?.identities.claudeEmail,
                    info: snapshot?.output?.claude,
                    windows: [.fiveHour, .sevenDay]
                )
                UsageServiceCard(
                    label: "Codex",
                    email: snapshot?.identities.codexEmail,
                    info: snapshot?.output?.codex,
                    windows: [.fiveHour, .sevenDay]
                )
                UsageServiceCard(
                    label: "Gemini",
                    email: snapshot?.identities.geminiEmail,
                    info: snapshot?.output?.gemini,
                    windows: [.twentyFourHour]
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

    private func timeString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

private struct CurrentUsageRow: View {
    let snapshot: UsageSnapshot?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(snapshot?.profileName ?? "Current")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Text("UNSAVED")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )

                Spacer()

                if let snapshot, let fetchedAt = snapshot.fetchedAt {
                    Text(timeString(fetchedAt))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(snapshot.isStale ? 0.35 : 0.45))
                }
            }

            HStack(spacing: 10) {
                UsageServiceCard(
                    label: "Claude",
                    email: snapshot?.identities.claudeEmail,
                    info: snapshot?.output?.claude,
                    windows: [.fiveHour, .sevenDay]
                )
                UsageServiceCard(
                    label: "Codex",
                    email: snapshot?.identities.codexEmail,
                    info: snapshot?.output?.codex,
                    windows: [.fiveHour, .sevenDay]
                )
                UsageServiceCard(
                    label: "Gemini",
                    email: snapshot?.identities.geminiEmail,
                    info: snapshot?.output?.gemini,
                    windows: [.twentyFourHour]
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

    private func timeString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

private struct UsageServiceCard: View {
    enum Window: CaseIterable {
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

    let label: String
    let email: String?
    let info: CLIUsageInfo?
    let windows: [Window]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let info, !info.available {
                Text("Not installed")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(TerminalColors.dim)
            } else if let info, info.error {
                Text("ERR")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
            } else {
                if label == "Gemini" {
                    GeminiUsageSummaryRow(info: info)
                } else {
                    ForEach(windows, id: \.label) { window in
                        UsageWindowRow(
                            window: window,
                            percentUsed: percentUsed(for: window),
                            resetAt: resetAt(for: window)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func percentUsed(for window: Window) -> Double? {
        guard let info, info.available, !info.error else { return nil }
        switch window {
        case .fiveHour, .twentyFourHour: return info.fiveHourPercent
        case .sevenDay: return info.sevenDayPercent
        }
    }

    private func resetAt(for window: Window) -> Date? {
        guard let info, info.available, !info.error else { return nil }
        switch window {
        case .fiveHour, .twentyFourHour: return info.fiveHourReset
        case .sevenDay: return info.sevenDayReset
        }
    }
}

private struct GeminiUsageSummaryRow: View {
    let info: CLIUsageInfo?

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

            Text("(Resets in \(timeRemainingString))")
                .foregroundColor(.white.opacity(0.28))
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

    private var timeRemainingString: String {
        guard let resetAt = info?.fiveHourReset else { return "--" }
        let seconds = max(0, Int(resetAt.timeIntervalSince(Date())))
        return formatDuration(seconds)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "<1m" }

        var remaining = seconds
        let days = remaining / 86_400
        remaining %= 86_400
        let hours = remaining / 3_600
        remaining %= 3_600
        let minutes = remaining / 60

        if days > 0 {
            let hh = String(format: "%02d", hours)
            let mm = String(format: "%02d", minutes)
            return "\(days)d \(hh)h \(mm)m"
        }

        if hours > 0 {
            let mm = String(format: "%02d", minutes)
            return "\(hours)h \(mm)m"
        }

        return "\(minutes)m"
    }
}

private struct UsageWindowRow: View {
    let window: UsageServiceCard.Window
    let percentUsed: Double?
    let resetAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 18, alignment: .leading)

            MiniUsageBar(fraction: remainingFraction)
                .frame(height: 6)
                .frame(width: 46)

            Text(remainingPercentString)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(remainingColor)
                .frame(width: 32, alignment: .trailing)

            Text(timeRemainingString)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var remainingFraction: Double {
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

    private var remainingColor: Color {
        guard let percentUsed else { return TerminalColors.dim }
        let used = max(0, min(100, percentUsed))
        let remaining = max(0, min(100, 100 - used))
        if remaining < 10 { return TerminalColors.red }
        if remaining < 25 { return TerminalColors.amber }
        return TerminalColors.green
    }

    private var timeRemainingString: String {
        guard let resetAt else { return "--" }
        let seconds = max(0, Int(resetAt.timeIntervalSince(Date())))
        return formatDuration(seconds)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "<1m" }

        var remaining = seconds
        let days = remaining / 86_400
        remaining %= 86_400
        let hours = remaining / 3_600
        remaining %= 3_600
        let minutes = remaining / 60

        if days > 0 {
            let hh = String(format: "%02d", hours)
            let mm = String(format: "%02d", minutes)
            return "\(days)d\(hh)h\(mm)m"
        }

        if hours > 0 {
            let mm = String(format: "%02d", minutes)
            return "\(hours)h\(mm)m"
        }

        return "\(minutes)m"
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MiniUsageBar: View {
    let fraction: Double

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
                        .fill(index < filledSegments ? fillColor : Color.white.opacity(0.08))
                        .frame(width: segmentWidth)
                }
            }
        }
    }

    private var fillColor: Color {
        if fraction < 0.1 { return TerminalColors.red }
        if fraction < 0.25 { return TerminalColors.amber }
        return TerminalColors.green
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
